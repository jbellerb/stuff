package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	usage = `gt [-r dir] [-p pattern] <command> [arguments]`
	help  = `
gotestd is a project-scoped daemon that watches a Go project's source and keeps
"go test" running against it.

The commands are:

	start      Spawn the daemon for this project, if not already running
	stop       Ask the daemon to exit
	status     Print the most recent test result
	tui        Display a live dashboard of the results

Flags:

	-r dir
		Project root. The default is the nearest directory above the
		current one containing a go.mod file.

	-p pattern
		Package pattern to test. The default is "./...".

Use "gt help <command>" for more information about a command

`
)

func usageFunc(fs *flag.FlagSet, usage string) func() {
	var cmd string
	if fs.Name() != "" {
		cmd = " " + fs.Name()
	}

	return func() {
		fmt.Fprint(os.Stderr, "usage: ")
		fmt.Fprintln(os.Stderr, usage)
		fmt.Fprintf(os.Stderr, "Run 'gt help%s' for usage.\n", cmd)
	}
}

func rejectExtraArgs(fs *flag.FlagSet) error {
	if fs.NArg() > 0 {
		fs.Usage()
		return fmt.Errorf("unexpected argument: %q", fs.Arg(0))
	}
	return nil
}

var commandHelp = map[string]struct{ usage, help string }{
	"start":  {startUsage, startHelp},
	"stop":   {stopUsage, stopHelp},
	"status": {statusUsage, statusHelp},
	"tui":    {tuiUsage, tuiHelp},
}

func main() {
	fs := flag.NewFlagSet("", flag.ExitOnError)
	fs.Usage = usageFunc(fs, usage)

	root := fs.String("r", "", "project root")
	pkg := fs.String("p", "./...", "package pattern to test")

	findPaths := func(root, pkg string) Paths {
		if root == "" {
			cwd, err := os.Getwd()
			if err == nil {
				root, err = FindRoot(cwd)
			}
			if err != nil {
				fmt.Fprintf(os.Stderr, "gt: %v\n", err)
				os.Exit(1)
			}
		}

		paths, err := RuntimePaths(root, pkg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "gt: %v\n", err)
			os.Exit(1)
		}

		return paths
	}

	_ = fs.Parse(os.Args[1:])
	if fs.NArg() == 0 {
		fmt.Println(usage)
		fmt.Print(help)
		os.Exit(2)
	}

	args := fs.Args()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	var err error
	switch cmd, args := args[0], args[1:]; cmd {
	case "start":
		err = runStart(ctx, findPaths(*root, *pkg), args)
	case "stop":
		err = runStop(ctx, findPaths(*root, *pkg), args)
	case "status":
		err = runStatus(ctx, findPaths(*root, *pkg), args)
	case "tui":
		err = runTui(ctx, findPaths(*root, *pkg), args)
	case "daemon":
		err = runDaemon(ctx, findPaths(*root, *pkg), args)
	case "help":
		if len(args) > 0 {
			if h, ok := commandHelp[args[0]]; ok {
				fmt.Println(h.usage)
				fmt.Print(h.help)
			} else {
				fmt.Fprintf(os.Stderr, "unknown command: %s\n", args[0])
				os.Exit(2)
			}
		} else {
			fmt.Println(usage)
			fmt.Print(help)
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", cmd)
		fs.Usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "gt %s: %v\n", args[0], err.Error())
		os.Exit(1)
	}
}

const (
	startUsage = `gt [-r dir] [-p pattern] start`
	startHelp  = `
Start spawns the daemon if it's not already running.

`
)

func runStart(ctx context.Context, paths Paths, args []string) error {
	fs := flag.NewFlagSet("start", flag.ExitOnError)
	fs.Usage = usageFunc(fs, startUsage)

	_ = fs.Parse(args)
	if err := rejectExtraArgs(fs); err != nil {
		return err
	}

	c := NewClient(paths.Socket)
	if c.Ping(ctx) == nil {
		return errors.New("daemon already running")
	}

	self, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locating own executable: %w", err)
	}

	cmd := exec.Command(self, "-r", paths.Root, "-p", paths.Pkg, "daemon")
	cmd.Dir = paths.Root
	cmd.Stdin = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // detach

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("piping daemon stderr: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting daemon: %w", err)
	}

	var errorOutput bytes.Buffer
	exited := make(chan error, 1)
	go func() {
		_, _ = io.Copy(&errorOutput, stderr)
		exited <- cmd.Wait()
	}()

	ticker := time.NewTicker(200 * time.Millisecond)
	deadline := time.After(10 * time.Second)
	for {
		select {
		case werr := <-exited:
			// exit here instead of returning an error since the daemon has
			// already formatted the error output
			fmt.Print(errorOutput.String())
			if eerr, ok := errors.AsType[*exec.ExitError](werr); ok {
				os.Exit(eerr.ExitCode())
			} else {
				os.Exit(1)
			}

		case <-ticker.C:
			if c.Ping(ctx) == nil {
				fmt.Printf(
					"started for %s (pkg %s, log %s)\n", paths.Root, paths.Pkg, paths.Log,
				)
				return nil
			}

		case <-deadline:
			return errors.New("request timed out")

		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

const (
	stopUsage = `gt [-r dir] [-p pattern] stop [-f]`
	stopHelp  = `
Stop asks the daemon to exit.

Flags:

	-f
		Skip the graceful shutdown request when stopping the daemon.

`
)

func runStop(ctx context.Context, paths Paths, args []string) error {
	fs := flag.NewFlagSet("stop", flag.ExitOnError)
	fs.Usage = usageFunc(fs, stopUsage)

	force := fs.Bool("f", false, "force stop the daemon")

	_ = fs.Parse(args)
	if err := rejectExtraArgs(fs); err != nil {
		return err
	}

	pid, ok := readPid(paths.Pid)
	if !pidfileLocked(paths.Pid) {
		_ = os.Remove(paths.Pid) // pidfile is stale
		ok = false
	}
	if !ok {
		fmt.Println("not running")
		return nil
	}

	var err error
	if *force {
		if err = syscall.Kill(pid, syscall.SIGKILL); err == nil {
			fmt.Println("stopped (SIGKILL)")
		}
	} else {
		c := NewClient(paths.Socket)
		err = c.Stop(ctx)
	}
	if err == nil {
		ticker := time.NewTicker(200 * time.Millisecond)
		defer ticker.Stop()
		deadline := time.After(3 * time.Second)
	waitLoop:
		for {
			select {
			case <-ticker.C:
				if !pidfileLocked(paths.Pid) {
					fmt.Println("stopped")
					return nil
				}
			case <-deadline:
				err = errors.New("request timed out")
				break waitLoop
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}

	if err != nil {
		return fmt.Errorf("could not stop daemon (pid %d): %w", pid, err)
	}

	return nil
}

const (
	statusUsage = `gt [-r dir] [-p pattern] status [-w]`
	statusHelp  = `
Status prints the most recent test result. If the result is a failure,
status exits with a nonzero exit code.

Flags:

	-w
		Wait for any in-flight test run to finish before printing.

`
)

func runStatus(ctx context.Context, paths Paths, args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	fs.Usage = usageFunc(fs, statusUsage)

	wait := fs.Bool("w", false, "wait for any in-flight test run to finish")

	_ = fs.Parse(args)
	if err := rejectExtraArgs(fs); err != nil {
		return err
	}

	c := NewClient(paths.Socket)

	var s State
	var err error
	if *wait {
		s, err = c.Wait(ctx)
	} else {
		s, err = c.Status(ctx)
	}
	if err != nil {
		return err
	}

	printState(s)

	if s.Phase == PhaseFailed {
		os.Exit(1)
	}

	return nil
}

const (
	tuiUsage = `gt [-r dir] [-p pattern] tui`
	tuiHelp  = `
TUI shows a live dashboard of test results.

`
)

func runTui(ctx context.Context, paths Paths, args []string) error {
	fs := flag.NewFlagSet("tui", flag.ExitOnError)
	fs.Usage = usageFunc(fs, tuiUsage)

	_ = fs.Parse(args)
	if err := rejectExtraArgs(fs); err != nil {
		return err
	}

	c := NewClient(paths.Socket)

	err := c.Ping(ctx)
	if errors.Is(err, ErrDaemonNotRunning) {
		err = runStart(ctx, paths, []string{})
	}
	if err != nil {
		return err
	}

	ws, err := c.Watch(ctx)
	if err != nil {
		return err
	}
	defer ws.Close()

	return tuiLoop(ctx, &ws)
}

func runDaemon(ctx context.Context, paths Paths, args []string) error {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	fs.Usage = usageFunc(fs, "gt [-r dir] [-p pattern] daemon")

	_ = fs.Parse(args)
	if err := rejectExtraArgs(fs); err != nil {
		return err
	}

	pidFile, err := os.OpenFile(paths.Pid, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return err
	}
	defer pidFile.Close()

	// hold an advisory exclusive lock on the pidfile for as long as this
	// process is alive. Whoever inspects the pidfile later can tell a live
	// daemon from a stale pidfile by checking if the lock is still held.
	var lockErr error
	if fConn, err := pidFile.SyscallConn(); err == nil {
		fConn.Control(func(fd uintptr) {
			lockErr = syscall.FcntlFlock(fd, syscall.F_SETLK, &syscall.Flock_t{
				Type:   syscall.F_WRLCK,
				Whence: int16(io.SeekStart),
			})
		})
	}
	if lockErr != nil {
		if errors.Is(lockErr, syscall.EAGAIN) || errors.Is(lockErr, syscall.EACCES) {
			return errors.New("daemon already running")
		}
		return lockErr
	}

	if err := pidFile.Truncate(0); err != nil {
		return err
	}
	if _, err := pidFile.WriteAt([]byte(strconv.Itoa(os.Getpid())), 0); err != nil {
		return err
	}
	defer os.Remove(paths.Pid)

	logf, err := os.OpenFile(paths.Log, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return fmt.Errorf("opening log file: %w", err)
	}
	defer logf.Close()
	os.Stdout = logf
	os.Stderr = logf

	log.SetOutput(logf)
	log.SetPrefix("gt daemon: ")
	log.Printf("watching %s (%s), socket %s", paths.Root, paths.Pkg, paths.Socket)

	if err := daemonLoop(ctx, paths); err != nil {
		return err
	}

	return nil
}

func printState(s State) {
	fmt.Printf("phase:   %s\n", s.Phase)
	fmt.Printf("root:    %s\n", s.Root)
	fmt.Printf("pkg:     %s\n", s.Pkg)
	if !s.EndedAt.IsZero() {
		fmt.Printf("took:    %s\n", s.EndedAt.Sub(s.StartedAt).Round(time.Millisecond))
	}
	if s.RunErr != "" {
		fmt.Printf("run error: %s\n", s.RunErr)
	}
	if s.Output != "" {
		fmt.Println()
		fmt.Println(s.Output)
	}
}

func readPid(path string) (pid int, ok bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	pid, err = strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return 0, false
	}
	return pid, true
}

func pidfileLocked(path string) bool {
	f, err := os.OpenFile(path, os.O_RDWR, 0o644)
	if err != nil {
		return false
	}
	defer f.Close()

	var lockErr error
	if fConn, err := f.SyscallConn(); err == nil {
		fConn.Control(func(fd uintptr) {
			lockErr = syscall.FcntlFlock(fd, syscall.F_SETLK, &syscall.Flock_t{
				Type:   syscall.F_WRLCK,
				Whence: int16(io.SeekStart),
			})
		})
	}

	return errors.Is(lockErr, syscall.EAGAIN) || errors.Is(lockErr, syscall.EACCES)
}
