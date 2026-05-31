package main

import (
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/coder/websocket"
)

//go:embed index.html
var frontendHtml []byte

//go:embed index.js
var frontendJs []byte

//go:embed main.css
var frontendCss []byte

const (
	usage = `remote [-a addr]`
	help  = `
Remote is a WebSocket server for TTY sessions.

Flags:

	-a addr
		Bind the WebSocket server to a specific address. The default is ":8080".

Environment Variables:

	SHELL
		The shell to use for TTY sessions. The default is the current
		user's default shell defined in "/etc/passwd".

Remote does not support any form of authentication or encryption, and it must be
served behind a TLS-terminating proxy. In addition to the WebSocket endpoint,
remote provides a graphical terminal emulator based on xterm.js.

Remote speaks a simple WebSocket protocol similar to SSH. Clients should
initiate a new session by opening a new WebSocket connection to "/" with the
subprotocol "remote.v1".

Initial connection parameters are set with query parameters:

	term
		The TERM environment variable value. The default is "xterm-256color".

	cols
		The initial number of columns for the TTY session. The default is 80.

	rows
		The initial number of rows for the TTY session. The default is 24.

	width
		The initial width in pixels for the TTY session. The default is 640.

	height
		The initial height in pixels for the TTY session. The default is 480.

	modes
		Initial TTY modes for the TTY session. This is a base64url-encoded
		string of the "encoded terminal modes" byte stream defined in RFC 4254.
		All modes defined in RFC 4254 and RFC 8160 are supported. The default
		is an empty byte stream.

The "remote.v1" protocol uses three message types: binary messages containing
the raw byte stream from the TTY session, text messages containing JSON-encoded
control messages, and ping messages. Control messages all contain a "type" field
and some number of additional fields depending on the message type.

The "window-change" control message is sent by the client to indicate a change
in the size of the terminal window. It follows the following schema:

	{
		"type": "window-change",
		"cols": <number of columns>,
		"rows": <number of rows>,
		"width": <width in pixels>,
		"height": <height in pixels>
	}

The "signal" control message is sent by the client to indicate that a signal
should be sent to the TTY session. It follows the following schema:

	{
		"type": "signal",
		"name": <signal name without the "SIG" prefix>
	}

`
)

type msgFrame struct {
	Type string `json:"type"`
}

type signalMsg struct {
	Name string `json:"name"`
}

type windowChangeMsg struct {
	Cols   uint16 `json:"cols"`
	Rows   uint16 `json:"rows"`
	Width  uint16 `json:"width"`
	Height uint16 `json:"height"`
}

var signalNames = map[string]syscall.Signal{
	"HUP":    syscall.SIGHUP,
	"INT":    syscall.SIGINT,
	"QUIT":   syscall.SIGQUIT,
	"ILL":    syscall.SIGILL,
	"TRAP":   syscall.SIGTRAP,
	"ABRT":   syscall.SIGABRT,
	"BUS":    syscall.SIGBUS,
	"FPE":    syscall.SIGFPE,
	"KILL":   syscall.SIGKILL,
	"USR1":   syscall.SIGUSR1,
	"SEGV":   syscall.SIGSEGV,
	"USR2":   syscall.SIGUSR2,
	"PIPE":   syscall.SIGPIPE,
	"ALRM":   syscall.SIGALRM,
	"TERM":   syscall.SIGTERM,
	"CHLD":   syscall.SIGCHLD,
	"CONT":   syscall.SIGCONT,
	"STOP":   syscall.SIGSTOP,
	"TSTP":   syscall.SIGTSTP,
	"TTIN":   syscall.SIGTTIN,
	"TTOU":   syscall.SIGTTOU,
	"URG":    syscall.SIGURG,
	"XCPU":   syscall.SIGXCPU,
	"XFSZ":   syscall.SIGXFSZ,
	"VTALRM": syscall.SIGVTALRM,
	"PROF":   syscall.SIGPROF,
	"WINCH":  syscall.SIGWINCH,
}

func main() {
	fs := flag.NewFlagSet("remote", flag.ContinueOnError)
	fs.SetOutput(io.Discard) // suppress "flag" printing errors

	addr := fs.String("a", ":8080", "address to serve on")
	showHelp := fs.Bool("h", false, "show help")

	err := fs.Parse(os.Args[1:])
	if err == nil && fs.NArg() > 0 {
		err = fmt.Errorf("unexpected argument: %q", fs.Arg(0))
	}
	if err != nil {
		fmt.Fprintf(
			os.Stderr,
			"%v\n\nusage: %s\n\nRun 'remote -h' for more information.\n",
			err,
			usage,
		)
		os.Exit(2)
	}

	if *showHelp {
		fmt.Fprint(os.Stderr, help)
		os.Exit(0)
	}

	level := slog.LevelInfo
	if lvl, ok := os.LookupEnv("REMOTE_LOG"); ok {
		if err := level.UnmarshalText([]byte(lvl)); err != nil {
			fmt.Fprintf(os.Stderr, "remote: invalid log level in REMOTE_LOG: %v\n", err)
			os.Exit(2)
		}
	}
	initLogger(level)

	os.Exit(serve(context.Background(), *addr))
}

func serve(ctx context.Context, addr string) int {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go waitForGracefulShutdown(ctx, cancel)

	var lc net.ListenConfig
	l, err := lc.Listen(ctx, "tcp", addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "remote: %v\n", err)
		return 1
	}

	sChan := make(chan error)
	s := &http.Server{
		Handler: newRouter(),
		ConnContext: func(ctx context.Context, c net.Conn) context.Context {
			return WithLogAttrs(
				ctx,
				slog.String("server.addr", c.LocalAddr().String()),
				slog.String("conn.addr", c.RemoteAddr().String()),
			)
		},
	}
	go func() { sChan <- s.Serve(l) }()
	slog.InfoContext(ctx, "Started HTTP server", "server.addr", l.Addr().String())

	select {
	case err := <-sChan:
		if err != http.ErrServerClosed {
			fmt.Fprintf(os.Stderr, "remote: %v\n", err)
			return 1
		}
	case <-ctx.Done():
		// TODO: should this have a timeout?
		if err := s.Shutdown(context.Background()); err != nil {
			fmt.Fprintf(os.Stderr, "remote: %v\n", err)
			return 1
		}
	}

	return 0
}

func waitForGracefulShutdown(ctx context.Context, cancel context.CancelFunc) {
	done := make(chan os.Signal, 1)
	signal.Notify(done, os.Interrupt, syscall.SIGTERM)

	select {
	case sig := <-done:
		slog.InfoContext(ctx, "Starting graceful shutdown", "shutdown.signal", sig)
		cancel()
	case <-ctx.Done():
		return
	}

	select {
	case sig := <-done:
		slog.ErrorContext(ctx, "Aborting", "shutdown.abort_signal", sig)
		os.Exit(1)
	case <-ctx.Done():
		return
	}
}

type router struct {
	mux *http.ServeMux
}

func newRouter() *router {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			handleWebSocket(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(frontendHtml)
	})
	mux.HandleFunc("/index.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.Write(frontendJs)
	})
	mux.HandleFunc("/main.css", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		w.Write(frontendCss)
	})

	return &router{mux}
}

func (r *router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	r.mux.ServeHTTP(w, req)
}

func defaultShell() string {
	uid := fmt.Sprintf("%d", os.Getuid())
	data, _ := os.ReadFile("/etc/passwd")
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.SplitN(line, ":", 7)
		if len(fields) == 7 && fields[2] == uid && fields[6] != "" {
			return fields[6]
		}
	}
	return "/bin/sh"
}

func startShell(
	shell string,
	env []string,
	slavePath string,
	rows, cols, width, height uint16,
	modes map[byte]uint32,
) (*os.Process, error) {
	slave, err := os.OpenFile(slavePath, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	defer slave.Close()

	if err := setWinsize(slave, rows, cols, width, height); err != nil {
		return nil, err
	}

	if err := applyModes(slave, modes); err != nil {
		return nil, err
	}

	return os.StartProcess(shell, []string{shell, "-l"}, &os.ProcAttr{
		Env:   env,
		Files: []*os.File{slave, slave, slave},
		Sys: &syscall.SysProcAttr{
			Setsid:  true,
			Setctty: true,
			Ctty:    0,
		},
	})
}

func handleWebSocket(w http.ResponseWriter, req *http.Request) {
	ctx := req.Context()
	q := req.URL.Query()

	term := q.Get("term")
	if term == "" {
		term = "xterm-256color"
	}
	parseUint16 := func(s string, def uint16) uint16 {
		if n, err := strconv.ParseUint(s, 10, 16); err == nil {
			return uint16(n)
		}
		return def
	}
	cols := parseUint16(q.Get("cols"), 80)
	rows := parseUint16(q.Get("rows"), 24)
	width := parseUint16(q.Get("width"), 640)
	height := parseUint16(q.Get("height"), 480)

	var modes map[byte]uint32
	if modesStr := q.Get("modes"); modesStr != "" {
		modesData, err := base64.RawURLEncoding.DecodeString(modesStr)
		if err != nil {
			slog.ErrorContext(ctx, "Failed to decode modes parameter", "exception", err)
			http.Error(w, "Invalid modes parameter", http.StatusBadRequest)
			return
		}
		modes, err = parseModes(modesData)
		if err != nil {
			slog.ErrorContext(ctx, "Failed to parse modes parameter", "exception", err)
			http.Error(w, "Invalid modes parameter", http.StatusBadRequest)
			return
		}
	}

	var wg sync.WaitGroup
	defer wg.Wait() // defer wg.Wait before any other cleanup so it runs first

	master, slavePath, err := openPty()
	if err != nil {
		slog.ErrorContext(ctx, "Failed to open PTY", "exception", err)
		http.Error(w, "Failed to open PTY", http.StatusInternalServerError)
		return
	}
	defer master.Close()

	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = defaultShell()
	}
	env := []string{
		"TERM=" + term,
		"PATH=" + os.Getenv("PATH"),
		"SHELL=" + shell,
	}

	ctx = WithLogAttrs(
		ctx,
		slog.String("session.pty.slave_path", slavePath),
		slog.String("session.pty.term", term),
		slog.String("session.pty.shell", shell),
	)

	proc, err := startShell(shell, env, slavePath, rows, cols, width, height, modes)
	if err != nil {
		slog.ErrorContext(ctx, "Failed to start shell", "exception", err)
		http.Error(w, "Failed to start shell", http.StatusInternalServerError)
		return
	}
	ctx = WithLogAttrs(ctx, slog.Int("session.pid", proc.Pid))

	c, err := websocket.Accept(w, req, &websocket.AcceptOptions{
		Subprotocols: []string{"remote.v1"},
	})
	if err != nil {
		slog.ErrorContext(ctx, "Failed to accept WebSocket connection", "exception", err)
		http.Error(w, "Failed to accept WebSocket connection", http.StatusInternalServerError)
		return
	}

	if c.Subprotocol() != "remote.v1" {
		slog.ErrorContext(
			ctx,
			"Unexpected WebSocket subprotocol",
			"exception", errors.New("Unsupported protocol"),
			"ws.subprotocol", c.Subprotocol(),
		)
		c.Close(websocket.StatusPolicyViolation, "Unsupported protocol")
		return
	} else {
		slog.DebugContext(ctx, "Started session")
	}

	wg.Go(func() {
		res, _ := proc.Wait()
		// skip closing master if we were terminated by SIGHUP
		if res.ExitCode() != 129 {
			master.Close()
		}
		slog.DebugContext(ctx, "Shell exited", "session.exit_code", res.ExitCode())
		c.Close(
			websocket.StatusNormalClosure,
			fmt.Sprintf("Shell exited with code %d", res.ExitCode()),
		)
	})

	wg.Go(func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := master.Read(buf)
			if err != nil {
				// this was either an accident or on purpose. Regardless, one of
				// the other two error handlers will catch this.
				master.Close()
				return
			}
			if n > 0 {
				c.Write(ctx, websocket.MessageBinary, buf[:n])
			}
		}
	})

	for {
		typ, data, err := c.Read(ctx)
		if err != nil {
			var ce websocket.CloseError
			if !errors.As(err, &ce) {
				slog.ErrorContext(ctx, "Error reading from WebSocket", "exception", err)
				c.CloseNow()
			} else if ce.Code != websocket.StatusNormalClosure {
				slog.InfoContext(
					ctx,
					"WebSocket closed",
					"ws.close.code", ce.Code,
					"ws.close.reason", ce.Reason,
				)
			}
			return
		}
		switch typ {
		case websocket.MessageBinary:
			master.Write(data)
		case websocket.MessageText:
			var ctrl msgFrame
			if json.Unmarshal(data, &ctrl) != nil {
				slog.ErrorContext(ctx, "Failed to parse control message", "exception", err)
				c.Close(websocket.StatusProtocolError, "Failed to parse control message")
				return
			}
			switch ctrl.Type {
			case "window-change":
				var wc windowChangeMsg
				if json.Unmarshal(data, &wc) != nil {
					slog.ErrorContext(
						ctx,
						"Failed to parse window-change message",
						"exception", err,
					)
					c.Close(websocket.StatusProtocolError, "Failed to parse window-change message")
					return
				}
				err := setWinsize(master, wc.Rows, wc.Cols, wc.Width, wc.Height)
				if err != nil {
					slog.ErrorContext(ctx, "Failed to change window size", "exception", err)
					c.Close(websocket.StatusInternalError, "Failed to change window size")
					return
				}
				slog.DebugContext(
					ctx,
					"Window size changed",
					"session.pty.window.cols", wc.Cols,
					"session.pty.window.rows", wc.Rows,
					"session.pty.window.width", wc.Width,
					"session.pty.window.height", wc.Height,
				)
			case "signal":
				var sc signalMsg
				if json.Unmarshal(data, &sc) != nil {
					slog.ErrorContext(ctx, "Failed to parse signal message", "exception", err)
					c.Close(websocket.StatusProtocolError, "Failed to parse signal message")
					return
				}
				if sig, ok := signalNames[sc.Name]; ok {
					proc.Signal(sig)
				} else {
					slog.WarnContext(
						ctx,
						"Unknown signal name in signal message",
						"ws.control.signal.name", sc.Name,
					)
					c.Close(websocket.StatusProtocolError, "Unknown signal name")
					return
				}
			default:
				slog.WarnContext(ctx, "Unknown control message type", "ws.control.type", ctrl.Type)
				c.Close(websocket.StatusProtocolError, "Unknown control message type")
				return
			}
		default:
			slog.WarnContext(
				ctx,
				"Received unsupported WebSocket message type",
				"ws.message.type", typ,
			)
		}
	}
}

// parseModes parses an RFC 4254 "encoded terminal modes" byte stream and
// returns a map from opcode to value. Parsing stops at TTY_OP_END (0x00) or
// undefined opcode (160–255).
func parseModes(data []byte) (map[byte]uint32, error) {
	modes := make(map[byte]uint32)
	for len(data) > 0 {
		opcode := data[0]
		data = data[1:]
		if opcode == 0 {
			break
		}
		if opcode > 159 {
			break
		}
		if len(data) < 4 {
			return nil, errors.New("truncated terminal mode stream")
		}
		modes[opcode] = binary.BigEndian.Uint32(data[:4])
		data = data[4:]
	}
	return modes, nil
}

type loggingContextKey struct{}

type loggingContext struct {
	parent *loggingContext
	attrs  []slog.Attr
}

// WithLogAttrs adds a set of attributes to the context for [ContextHandler] to
// include in log output.
func WithLogAttrs(ctx context.Context, attrs ...slog.Attr) context.Context {
	parent, _ := ctx.Value(loggingContextKey{}).(*loggingContext)
	return context.WithValue(ctx, loggingContextKey{}, &loggingContext{parent, attrs})
}

// ContextHandler is a [slog.Handler] that pulls in extra attributes added to
// the context by [WithLogAttrs].
type ContextHandler struct {
	slog.Handler
}

// NewContextHandler returns a new instance of ContextHandler.
func NewContextHandler(handler slog.Handler) *ContextHandler {
	return &ContextHandler{handler}
}

func (h *ContextHandler) Handle(ctx context.Context, r slog.Record) error {
	data, ok := ctx.Value(loggingContextKey{}).(*loggingContext)
	if ok && data != nil {
		r.AddAttrs(slog.Bool("event", true))
		for data != nil {
			r.AddAttrs(data.attrs...)
			data = data.parent
		}
	}

	return h.Handler.Handle(ctx, r)
}

func initLogger(level slog.Level) {
	jsonHandler := slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: level})
	ctxHandler := NewContextHandler(jsonHandler)
	slog.SetDefault(slog.New(ctxHandler))
}
