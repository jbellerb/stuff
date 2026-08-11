package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// FindRoot walks up from start looking for the nearest directory containing
// a go.mod file.
func FindRoot(start string) (string, error) {
	dir, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("no go.mod found in this or any parent directory")
		}
		dir = parent
	}
}

// Paths are the filesystem locations a daemon instance uses to communicate with
// clients.
type Paths struct {
	Root   string // the watchman root
	Pkg    string // the package pattern
	Dir    string // runtime directory for this project
	Socket string // unix domain socket
	Pid    string // pidfile
	Log    string // daemon log (written by the client that spawns the daemon)
}

// RuntimePaths returns the runtime directory and well-known file paths for
// root.
//
// The directory lives under $XDG_RUNTIME_DIR when set, or /tmp otherwise. /tmp
// is used instead of os.TempDir() because Darwin makes unix socket paths longer
// than 104 bytes annoying.
func RuntimePaths(root, pkg string) (Paths, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return Paths{}, err
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		abs = resolved
	}

	sum := sha256.New()
	_ = binary.Write(sum, binary.LittleEndian, uint64(len(abs)))
	_, _ = sum.Write([]byte(abs))
	_ = binary.Write(sum, binary.LittleEndian, uint64(len(pkg)))
	_, _ = sum.Write([]byte(pkg))
	id := hex.EncodeToString(sum.Sum(nil)[:5]) // 10 hex chars, plenty to avoid collisions...

	base := os.Getenv("XDG_RUNTIME_DIR")
	if base != "" {
		base = filepath.Join(base, "gotestd")
	} else {
		base = fmt.Sprintf("/tmp/gotestd-%d", os.Getuid())
	}

	dir := filepath.Join(base, id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return Paths{}, fmt.Errorf("creating runtime dir: %w", err)
	}
	_ = os.Chmod(dir, 0o700)

	return Paths{
		Root:   abs,
		Pkg:    pkg,
		Dir:    dir,
		Socket: filepath.Join(dir, "sock"),
		Pid:    filepath.Join(dir, "pid"),
		Log:    filepath.Join(dir, "log"),
	}, nil
}
