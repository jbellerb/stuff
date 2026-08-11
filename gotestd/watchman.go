package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"sync"
)

type subscribeEvent struct {
	Files           []string `json:"files"`
	IsFreshInstance bool     `json:"is_fresh_instance"`
}

// Watchman is a live `watchman` subscription on a project's *.go files.
type Watchman struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser

	once     sync.Once
	changes  chan struct{}
	scanDone chan struct{}
}

// Watch starts `watchman watch-project` on root and subscribes to *.go file
// changes beneath it (excluding vendor/).
func Watch(root string) (*Watchman, error) {
	if _, err := exec.LookPath("watchman"); err != nil {
		return nil, fmt.Errorf("watchman not found in PATH: %w", err)
	}

	watchRoot, relRoot, err := watchProject(root)
	if err != nil {
		return nil, fmt.Errorf("watchman watch-project: %w", err)
	}

	cmd := exec.Command("watchman", "-j", "-p", "--no-pretty")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("starting watchman subscribe: %w", err)
	}

	query := map[string]any{
		"expression": []any{
			"allof",
			[]any{"type", "f"},
			[]any{"match", "*.go", "basename"},
			[]any{"not", []any{"match", "vendor/**", "wholename"}},
		},
		"fields": []string{"name"},
	}
	if relRoot != "" {
		query["relative_root"] = relRoot
	}
	sub := []any{"subscribe", watchRoot, "gotestd", query}
	if err := json.NewEncoder(stdin).Encode(sub); err != nil {
		_ = cmd.Process.Kill()
		return nil, fmt.Errorf("sending watchman subscribe request: %w", err)
	}

	w := &Watchman{
		cmd:      cmd,
		stdin:    stdin,
		changes:  make(chan struct{}, 1),
		scanDone: make(chan struct{}),
	}
	go w.scan(stdout)

	return w, nil
}

func (w *Watchman) scan(stdout io.Reader) {
	defer close(w.scanDone)

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		var ev subscribeEvent
		if err := json.Unmarshal(scanner.Bytes(), &ev); err != nil {
			continue
		}
		if ev.IsFreshInstance || len(ev.Files) == 0 {
			continue
		}
		select {
		case w.changes <- struct{}{}:
		default:
		}
	}
}

// Changes receives a value each time matching files change.
func (w *Watchman) Changes() <-chan struct{} {
	return w.changes
}

// Stop kills the watchman subprocess and drops the subscription.
func (w *Watchman) Stop() {
	w.once.Do(func() {
		w.stdin.Close()
		w.cmd.Process.Kill()
		w.cmd.Wait()
		// scan only sends on w.changes before it observes the closed stdout
		// pipe and returns. Waiting for it here guarantees no send
		// races the close below.
		<-w.scanDone
		close(w.changes)
	})
}

// watchProject issues a one-shot `watch-project` command and returns the watch
// root watchman actually chose (which may be an ancestor if the parent is
// already watched) along with root's path relative to it.
func watchProject(root string) (watchRoot, relRoot string, err error) {
	cmd := exec.Command("watchman", "-j", "--no-pretty")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return "", "", err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", "", err
	}
	if err := cmd.Start(); err != nil {
		return "", "", err
	}

	watch := []string{"watch-project", root}
	if err := json.NewEncoder(stdin).Encode(watch); err != nil {
		return "", "", err
	}
	_ = stdin.Close()

	var resp struct {
		Watch        string `json:"watch"`
		RelativePath string `json:"relative_path"`
		Error        string `json:"error"`
	}
	dec := json.NewDecoder(stdout)
	if err := dec.Decode(&resp); err != nil {
		return "", "", err
	}
	if err := cmd.Wait(); err != nil {
		return "", "", err
	}

	if resp.Error != "" {
		return "", "", fmt.Errorf("%s", resp.Error)
	}

	return resp.Watch, resp.RelativePath, nil
}
