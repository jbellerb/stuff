package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"tools/installer/internal/store"
)

func main() {
	tcpPort := flag.Int("tcp-port", 0, "TCP port for gRPC server")
	logPath := flag.String("log-path", "", "Path to write log output")
	gc := flag.Bool("gc", false, "Run garbage collection and exit")
	flag.Parse()

	st, err := store.NewStore(cacheDir())
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to initialize store: %v\n", err)
		os.Exit(1)
	}

	if *gc {
		if err := st.GC(); err != nil {
			fmt.Fprintf(os.Stderr, "garbage collection failed: %v\n", err)
			os.Exit(1)
		}
		return
	}

	s := NewServer(st)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	shutdownCtx, cancel := context.WithCancel(ctx)
	go waitForGracefulShutdown(ctx, cancel)

	bindCtx, cancel := context.WithTimeout(shutdownCtx, 5*time.Second)
	defer cancel()
	l, err := (&net.ListenConfig{}).Listen(bindCtx, "tcp", fmt.Sprintf(":%d", *tcpPort))
	if err != nil {
		if bindCtx.Err() != context.Canceled {
			fmt.Fprintf(os.Stderr, "failed to bind to socket: %v\n", err)
			os.Exit(1)
		}
		return
	}

	var logWriter io.Writer = os.Stderr
	if *logPath != "" {
		f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to open log file: %v\n", err)
			os.Exit(1)
		}
		defer f.Close()
		logWriter = f
	}

	initLogger(logWriter, slog.LevelInfo)

	slog.InfoContext(shutdownCtx, "Started gRPC server", "server.addr", l.Addr().String())
	if err := s.Serve(shutdownCtx, l); err != nil {
		slog.ErrorContext(shutdownCtx, "Socket unexpectedly closed", "exception", err)
	}
}

func waitForGracefulShutdown(ctx context.Context, cancel context.CancelFunc) {
	done := make(chan os.Signal, 1)
	signal.Notify(done, syscall.SIGINT, syscall.SIGTERM)

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

type loggingContextKey struct{}

type loggingContext struct {
	parent *loggingContext
	attrs  []slog.Attr
}

// withLogAttrs adds a set of attributes to the context for [contextHandler] to
// include in log output.
func withLogAttrs(ctx context.Context, attrs ...slog.Attr) context.Context {
	parent, _ := ctx.Value(loggingContextKey{}).(*loggingContext)
	return context.WithValue(ctx, loggingContextKey{}, &loggingContext{parent, attrs})
}

// contextHandler is a [slog.Handler] that pulls in extra attributes added to
// the context by [withLogAttrs].
type contextHandler struct {
	slog.Handler
}

func (h *contextHandler) Handle(ctx context.Context, r slog.Record) error {
	if data, ok := ctx.Value(loggingContextKey{}).(*loggingContext); ok {
		for data != nil {
			r.AddAttrs(data.attrs...)
			data = data.parent
		}
	}

	return h.Handler.Handle(ctx, r)
}

func initLogger(w io.Writer, level slog.Level) {
	jsonHandler := slog.NewJSONHandler(w, &slog.HandlerOptions{Level: level})
	ctxHandler := &contextHandler{jsonHandler}
	slog.SetDefault(slog.New(ctxHandler))
}

func cacheDir() string {
	if xdg := os.Getenv("XDG_CACHE_HOME"); xdg != "" {
		return xdg + "/installer"
	}

	homeDir, err := os.UserHomeDir()
	if err == nil {
		return homeDir + "/.cache/installer"
	}

	return ".cache/installer"
}
