package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"
	"time"
)

var (
	dialTimeout = 2 * time.Second

	debounce = 200 * time.Millisecond
)

var (
	ErrDaemonNotRunning = errors.New("daemon not running")
)

func daemonLoop(ctx context.Context, paths Paths) error {
	wm, err := Watch(paths.Root)
	if err != nil {
		return err
	}
	defer wm.Stop()

	_ = os.Remove(paths.Socket)
	ln, err := net.Listen("unix", paths.Socket)
	if err != nil {
		return err
	}
	defer ln.Close()

	ps := newPubSub(
		State{
			Phase:     PhaseRunning,
			Root:      paths.Root,
			Pkg:       paths.Pkg,
			Trigger:   TriggerStartup,
			StartedAt: time.Now(),
		},
	)

	trigger := make(chan Trigger, 1)
	stopServer := make(chan struct{})
	var stopOnce sync.Once
	stop := func() { stopOnce.Do(func() { close(stopServer) }) }

	go debounceLoop(wm.Changes(), trigger)
	go acceptLoop(ln, ps, stop)
	go func() {
		select {
		case <-ctx.Done():
			stop()
		case <-stopServer:
		}
	}()

	trigger <- TriggerStartup

	var cancel context.CancelFunc
	done := make(chan doneMsg, 1)
	var runID int

	for {
		select {
		case reason := <-trigger:
			if cancel != nil {
				cancel() // supersede any in-flight run
			}
			var runCtx context.Context
			runCtx, cancel = context.WithCancel(context.Background())
			runID++
			id := runID
			ps.publish(
				State{
					Phase:     PhaseRunning,
					Root:      paths.Root,
					Pkg:       paths.Pkg,
					Trigger:   reason,
					StartedAt: time.Now(),
				},
			)
			go func(ctx context.Context, id int) {
				res := runTests(ctx, paths.Root, paths.Pkg)
				if ctx.Err() != nil {
					return // superseded, the newer run owns publishing
				}
				done <- doneMsg{id: id, res: res}
			}(runCtx, id)

		case msg := <-done:
			if msg.id != runID {
				// stale result from a run superseded before this select case
				// was chosen, a newer run already owns publishing
				continue
			}
			s := ps.current()
			s.EndedAt = time.Now()
			s.Output = msg.res.Output
			s.RunErr = msg.res.RunErr
			if msg.res.RunErr != "" {
				s.Phase = PhaseFailed
			} else if msg.res.Passed {
				s.Phase = PhasePassed
			} else {
				s.Phase = PhaseFailed
			}
			ps.publish(s)

		case <-stopServer:
			if cancel != nil {
				cancel()
			}
			log.Println("stopping")
			return nil
		}
	}
}

// debounceLoop forwards watchman change signals to trigger, collapsing any that
// arrive within the debounce window into one "fs-change" trigger.
func debounceLoop(changes <-chan struct{}, trigger chan<- Trigger) {
	var timer *time.Timer
	var fire <-chan time.Time
	for {
		select {
		case <-changes:
			if timer == nil {
				timer = time.NewTimer(debounce)
			} else {
				timer.Reset(debounce)
			}
			fire = timer.C
		case <-fire:
			fire = nil
			select {
			case trigger <- TriggerFsChange:
			default:
			}
		}
	}
}

func acceptLoop(ln net.Listener, ps *pubSub, stop func()) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go handleConn(c, ps, stop)
	}
}

func handleConn(c net.Conn, ps *pubSub, stop func()) {
	defer c.Close()

	var req Request
	if err := json.NewDecoder(c).Decode(&req); err != nil {
		return
	}
	enc := json.NewEncoder(c)

	switch req.Cmd {
	case CmdPing:
		_ = enc.Encode(Ack{OK: true})

	case CmdStatus:
		_ = enc.Encode(ps.current())

	case CmdWait:
		sub := ps.subscribe()
		defer ps.unsubscribe(sub)
		for s := range sub {
			if s.Phase != PhaseRunning {
				_ = enc.Encode(s)
				return
			}
		}

	case CmdWatch:
		sub := ps.subscribe()
		defer ps.unsubscribe(sub)
		for {
			select {
			case s, ok := <-sub:
				if !ok {
					return
				}
				if err := enc.Encode(s); err != nil {
					return
				}
			}
		}

	case CmdStop:
		_ = enc.Encode(Ack{OK: true})
		stop()
	}
}

type pubSub struct {
	mu   sync.Mutex
	last State
	subs map[chan State]struct{}
}

func newPubSub(initial State) *pubSub {
	return &pubSub{last: initial, subs: make(map[chan State]struct{})}
}

func (ps *pubSub) publish(s State) {
	ps.mu.Lock()
	ps.last = s
	for ch := range ps.subs {
		select {
		case <-ch:
		default:
		}
		ch <- s
	}
	ps.mu.Unlock()
}

func (ps *pubSub) current() State {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	return ps.last
}

func (ps *pubSub) subscribe() chan State {
	ch := make(chan State, 1)
	ps.mu.Lock()
	ch <- ps.last
	ps.subs[ch] = struct{}{}
	ps.mu.Unlock()
	return ch
}

func (ps *pubSub) unsubscribe(ch chan State) {
	ps.mu.Lock()
	if _, ok := ps.subs[ch]; ok {
		delete(ps.subs, ch)
		close(ch)
	}
	ps.mu.Unlock()
}

type runResult struct {
	Passed bool
	Output string
	RunErr string // non-empty if `go test` couldn't be started at all
}

type doneMsg struct {
	id  int
	res runResult
}

func runTests(ctx context.Context, root, pkg string) runResult {
	cmd := exec.CommandContext(ctx, "go", "test", pkg)
	cmd.Dir = root

	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out

	err := cmd.Run()
	if ctx.Err() != nil {
		return runResult{}
	}
	if err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			return runResult{Passed: false, Output: out.String()}
		}
		return runResult{RunErr: err.Error(), Output: out.String()}
	}
	return runResult{Passed: true, Output: out.String()}
}

// Client is a handle for interacting with a running daemon.
type Client struct {
	socketPath string
}

func NewClient(path string) Client {
	return Client{socketPath: path}
}

func (c *Client) do(ctx context.Context, req Request) (net.Conn, func() bool, error) {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", c.socketPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			err = ErrDaemonNotRunning
		}
		return nil, nil, err
	}
	stop := context.AfterFunc(ctx, func() { conn.Close() })

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
		stop()
		conn.Close()
		return nil, nil, err
	}

	return conn, stop, nil
}

func (c *Client) Ping(ctx context.Context) error {
	conn, stop, err := c.do(ctx, Request{Cmd: CmdPing})
	if err != nil {
		return err
	}
	defer stop()
	defer conn.Close()

	var ack Ack
	err = json.NewDecoder(conn).Decode(&ack)
	if err != nil && ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

func (c *Client) Status(ctx context.Context) (State, error) {
	var state State

	conn, stop, err := c.do(ctx, Request{Cmd: CmdStatus})
	if err != nil {
		return state, err
	}
	defer stop()
	defer conn.Close()

	err = json.NewDecoder(conn).Decode(&state)
	if err != nil && ctx.Err() != nil {
		return state, ctx.Err()
	}
	return state, err
}

// WatchStream is a continuous stream of state updates.
type WatchStream struct {
	conn    net.Conn
	decoder *json.Decoder
}

func (ws *WatchStream) Next(ctx context.Context) (State, error) {
	stop := context.AfterFunc(ctx, func() { ws.conn.Close() })
	defer stop()

	var state State
	if err := ws.decoder.Decode(&state); err != nil {
		if err := ctx.Err(); err != nil {
			return state, err
		}
		return state, err
	}
	return state, nil
}

func (ws *WatchStream) Close() error {
	return ws.conn.Close()
}

func (c *Client) Watch(ctx context.Context) (WatchStream, error) {
	var ws WatchStream
	conn, stop, err := c.do(ctx, Request{Cmd: CmdWatch})
	if err != nil {
		return ws, err
	}
	stop() // dial and the initial request are done, and Next cancels per call

	ws.conn = conn
	ws.decoder = json.NewDecoder(ws.conn)
	return ws, nil
}

func (c *Client) Wait(ctx context.Context) (State, error) {
	var state State

	conn, stop, err := c.do(ctx, Request{Cmd: CmdWait})
	if err != nil {
		return state, err
	}
	defer stop()
	defer conn.Close()

	err = json.NewDecoder(conn).Decode(&state)
	if err != nil && ctx.Err() != nil {
		return state, ctx.Err()
	}
	return state, err
}

func (c *Client) Stop(ctx context.Context) error {
	conn, stop, err := c.do(ctx, Request{Cmd: CmdStop})
	if err != nil {
		return err
	}
	defer stop()
	defer conn.Close()

	var ack Ack
	err = json.NewDecoder(conn).Decode(&ack)
	if err != nil && ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}
