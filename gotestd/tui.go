package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"golang.org/x/term"
)

const (
	altScreenOn  = "\x1b[?1049h"
	altScreenOff = "\x1b[?1049l"
)

func tuiLoop(ctx context.Context, ws *WatchStream) error {
	states := make(chan State)
	go func() {
		for {
			s, err := ws.Next(ctx)
			if err != nil {
				close(states)
				return
			}
			states <- s
		}
	}()

	keys := make(chan byte)
	go func() {
		buf := make([]byte, 1)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				keys <- buf[0]
			}
			if err != nil {
				close(keys)
				return
			}
		}
	}()

	var oldState *term.State
	var err error
	if fConn, err := os.Stdin.SyscallConn(); err == nil {
		fConn.Control(func(fd uintptr) {
			oldState, err = term.MakeRaw(int(fd))
		})
	}
	if err != nil {
		return fmt.Errorf("entering raw mode: %w", err)
	}
	defer func() {
		if fConn, err := os.Stdin.SyscallConn(); err == nil {
			fConn.Control(func(fd uintptr) {
				term.Restore(int(fd), oldState)
			})
		}
	}()

	fmt.Print(altScreenOn)

	var status string
renderLoop:
	for {
		select {
		case s, ok := <-states:
			if !ok {
				status = "daemon connection closed\r\n"
				break renderLoop
			}
			render(s)

		case k, ok := <-keys:
			if !ok {
				break renderLoop
			}
			switch k {
			case 'q', 3: // 3 == ^C, since raw mode no longer generates SIGINT
				status = "detached (daemon keeps running in the background)\r\n"
				break renderLoop
			}

		case <-ctx.Done():
			status = "detached (daemon keeps running in the background)\r\n"
		}
	}

	fmt.Print(altScreenOff)
	if status != "" {
		fmt.Print(status)
	}

	return nil
}

func render(s State) {
	var status string
	switch s.Phase {
	case PhaseRunning:
		status = "RUNNING"
	case PhasePassed:
		status = "PASS"
	case PhaseFailed:
		status = "FAIL"
	default:
		status = string(s.Phase)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "gotestd   %s\n", status)
	fmt.Fprintf(&b, "root      %s\n", s.Root)
	fmt.Fprintf(&b, "pkg       %s\n", s.Pkg)
	if !s.EndedAt.IsZero() {
		fmt.Fprintf(&b, "last run %s (took %s)\n", s.EndedAt.Format(time.Kitchen), s.EndedAt.Sub(s.StartedAt).Round(time.Millisecond))
	}
	fmt.Fprintln(&b)

	if s.RunErr != "" {
		fmt.Fprintf(&b, "could not run go test: %s\n", s.RunErr)
	}
	if s.Output != "" {
		fmt.Fprintln(&b, tail(s.Output, 40))
	}

	fmt.Fprintln(&b, "[q] detach")

	fmt.Print("\x1b[H\x1b[J") // cursor to top-left, erase to end of screen
	fmt.Print(strings.ReplaceAll(b.String(), "\n", "\r\n"))
}

func tail(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) <= n {
		return s
	}
	omitted := len(lines) - n
	return fmt.Sprintf("... (%d lines omitted) ...\n%s", omitted, strings.Join(lines[len(lines)-n:], "\n"))
}
