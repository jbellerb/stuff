package main

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tools/installer/internal/store"
	pb "tools/installer/third-party/buckproto/install"
)

func TestMain(m *testing.M) {
	// supress logging
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	os.Exit(m.Run())
}

type testServer struct {
	*Server
	dir string
}

func newTestServer(t *testing.T) *testServer {
	t.Helper()

	dir := t.TempDir()
	st, err := store.NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore failed: %v", err)
	}
	return &testServer{Server: NewServer(st), dir: dir}
}

func (ts *testServer) writeFile(t *testing.T, name, content string) string {
	t.Helper()

	path := filepath.Join(ts.dir, name)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatalf("failed to create parent dirs: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("failed to create %s: %v", name, err)
	}
	return path
}

// install calls Install then FileReady for each file, returning the last
// FileReady response
func (ts *testServer) install(t *testing.T, id string, files map[string]string) *pb.FileResponse {
	t.Helper()

	req := &pb.InstallInfoRequest{InstallId: id, Files: files}
	if _, err := ts.Install(context.Background(), req); err != nil {
		t.Fatalf("Install failed: %v", err)
	}
	var last *pb.FileResponse
	for name, path := range files {
		resp, err := ts.FileReady(context.Background(), &pb.FileReadyRequest{
			InstallId: id, Name: name, Path: path,
		})
		if err != nil {
			t.Fatalf("FileReady failed: %v", err)
		}
		last = resp
	}
	return last
}

func TestInstall_RecordsFilesMap(t *testing.T) {
	ts := newTestServer(t)
	s := ts.Server

	req := &pb.InstallInfoRequest{
		InstallId: "//foo:bar",
		Files: map[string]string{
			"~/.config/foo.conf": "/buck-out/tmp/foo.conf",
			"~/.local/bin/foo":   "/buck-out/tmp/foo",
		},
	}

	resp, err := s.Install(context.Background(), req)
	if err != nil {
		t.Fatalf("Install failed: %v", err)
	}

	if resp.GetInstallId() != req.InstallId {
		t.Fatalf("expected install_id %s, got %s", req.InstallId, resp.GetInstallId())
	}

	state, ok := s.installs[req.InstallId]
	if !ok {
		t.Fatal("expected install to be logged")
	}
	if len(state.pending) != 2 {
		t.Fatalf("expected state to hold 2 pending files, got %d", len(state.pending))
	}

	for name := range req.Files {
		if _, ok := state.pending[name]; !ok {
			t.Errorf("expected file %s in pending state", name)
		}
	}

	if len(state.objects) != 0 {
		t.Errorf("expected no objects until FileReady, got %d", len(state.objects))
	}

	// Note: Install only creates in-memory tracking, actual install happens
	// as FileReady adds the finished artifacts.
}

func TestInstall_MultipleCalls(t *testing.T) {
	ts := newTestServer(t)

	req1 := &pb.InstallInfoRequest{
		InstallId: "//foo:bar",
		Files:     map[string]string{"~/.config/foo.conf": "/buck-out/tmp/foo.conf"},
	}
	req2 := &pb.InstallInfoRequest{
		InstallId: "//baz:qux",
		Files:     map[string]string{"~/.config/baz.conf": "/buck-out/tmp/baz.conf"},
	}

	if _, err := ts.Install(context.Background(), req1); err != nil {
		t.Fatalf("Install 1 failed: %v", err)
	}
	if _, err := ts.Install(context.Background(), req2); err != nil {
		t.Fatalf("Install 2 failed: %v", err)
	}

	installs, err := ts.store.GetInstalls()
	if err != nil {
		t.Fatalf("GetInstalls failed: %v", err)
	}
	if len(installs) != 0 {
		t.Errorf("expected 0 installs before FileReady, got %d", len(installs))
	}
}

func TestFileReady_CreatesSymlink(t *testing.T) {
	ts := newTestServer(t)
	src := ts.writeFile(t, "source.txt", "test")
	dst := filepath.Join(ts.dir, "destination.txt")

	resp := ts.install(t, "//test:target", map[string]string{dst: src})
	if resp.GetErrorDetail() != nil {
		t.Errorf("unexpected error: %s", resp.GetErrorDetail().GetMessage())
	}

	linkTarget, err := os.Readlink(dst)
	if err != nil {
		t.Fatalf("failed to read symlink: %v", err)
	}
	if !strings.HasPrefix(linkTarget, ts.store.StorePath()+"/") {
		t.Errorf("expected symlink to point to store object, got %s", linkTarget)
	}

	linkContent, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("failed to read through symlink: %v", err)
	}
	if string(linkContent) != "test" {
		t.Errorf("content mismatch: expected %q, got %q", "test", string(linkContent))
	}
}

func TestFileReady_CreatesParentDirectories(t *testing.T) {
	ts := newTestServer(t)
	src := ts.writeFile(t, "source.txt", "test")
	dst := filepath.Join(ts.dir, "nested", "dir", "destination.txt")

	ts.install(t, "//test:target", map[string]string{dst: src})

	if _, err := os.Stat(filepath.Dir(dst)); os.IsNotExist(err) {
		t.Error("parent directories were not created")
	}
	if _, err := os.Lstat(dst); os.IsNotExist(err) {
		t.Error("symlink was not created")
	}
}

func TestFileReady_ExpandsTilde(t *testing.T) {
	ts := newTestServer(t)
	src := ts.writeFile(t, "source.txt", "test")
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)

	ts.install(t, "//test:target", map[string]string{"~/.config/test.conf": src})

	if _, err := os.Lstat(filepath.Join(homeDir, ".config", "test.conf")); os.IsNotExist(err) {
		t.Error("symlink was not created at expanded path")
	}
}

func TestFileReady_OverwritesExistingSymlink(t *testing.T) {
	ts := newTestServer(t)
	src1 := ts.writeFile(t, "source1.txt", "test1")
	src2 := ts.writeFile(t, "source2.txt", "test2")
	dst := filepath.Join(ts.dir, "destination.txt")

	// create existing symlink pointing into the store
	digest1, err := ts.store.Put(src1)
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}
	if err := os.Symlink(ts.store.ObjectPath(digest1), dst); err != nil {
		t.Fatalf("failed to create initial symlink: %v", err)
	}

	ts.install(t, "//test:target", map[string]string{dst: src2})

	linkTarget, err := os.Readlink(dst)
	if err != nil {
		t.Fatalf("failed to read symlink: %v", err)
	}
	if !strings.Contains(linkTarget, "/objects/") {
		t.Errorf("expected symlink to point to store object, got %s", linkTarget)
	}

	linkContent, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("failed to read through symlink: %v", err)
	}
	if string(linkContent) != "test2" {
		t.Errorf("content mismatch: expected %q, got %q", "test2", string(linkContent))
	}
}

func TestFileReady_SkipsExistingRegularFile(t *testing.T) {
	ts := newTestServer(t)
	src := ts.writeFile(t, "source.txt", "test")
	dst := ts.writeFile(t, "destination.txt", "existing")

	resp := ts.install(t, "//test:target", map[string]string{dst: src})
	if resp.GetErrorDetail() == nil {
		t.Error("expected error detail for regular file, got nil")
	}

	content, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("failed to read file: %v", err)
	}
	if string(content) != "existing" {
		t.Errorf("file was modified: expected 'existing', got %q", string(content))
	}

	info, err := os.Lstat(dst)
	if err != nil {
		t.Fatalf("failed to stat file: %v", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Error("file was converted to symlink")
	}
}

func TestFileReady_SkipsExternalSymlink(t *testing.T) {
	ts := newTestServer(t)
	src := ts.writeFile(t, "source.txt", "test")
	external := ts.writeFile(t, "external.txt", "external")
	dst := filepath.Join(ts.dir, "destination.txt")
	if err := os.Symlink(external, dst); err != nil {
		t.Fatalf("failed to create symlink: %v", err)
	}

	resp := ts.install(t, "//test:target", map[string]string{dst: src})
	if resp.GetErrorDetail() == nil {
		t.Error("expected error for external symlink, got nil")
	}

	target, err := os.Readlink(dst)
	if err != nil {
		t.Fatalf("failed to read symlink: %v", err)
	}
	if target != external {
		t.Errorf("symlink was modified: expected %s, got %s", external, target)
	}
}

func TestFileReady_UnknownInstallId(t *testing.T) {
	ts := newTestServer(t)

	_, err := ts.FileReady(context.Background(), &pb.FileReadyRequest{
		InstallId: "//unknown:target",
		Name:      "~/.config/test.conf",
		Path:      "/buck-out/tmp/test.conf",
	})
	if err == nil {
		t.Error("expected error for unknown install id, got nil")
	}
}

func TestFileReady_UnknownFileName(t *testing.T) {
	ts := newTestServer(t)

	req := &pb.InstallInfoRequest{
		InstallId: "//test:target",
		Files:     map[string]string{"~/.config/foo.conf": "/buck-out/tmp/foo.conf"},
	}
	if _, err := ts.Install(context.Background(), req); err != nil {
		t.Fatalf("Install failed: %v", err)
	}

	_, err := ts.FileReady(context.Background(), &pb.FileReadyRequest{
		InstallId: "//test:target",
		Name:      "~/.config/unknown.conf",
		Path:      "/buck-out/tmp/unknown.conf",
	})
	if err == nil {
		t.Error("expected error for unknown file name, got nil")
	}
}

func TestFileReady_PartialInstall_NoSymlinks(t *testing.T) {
	ts := newTestServer(t)
	src1 := ts.writeFile(t, "source1.txt", "test1")
	src2 := ts.writeFile(t, "source2.txt", "test2")
	dst1 := filepath.Join(ts.dir, "destination1.txt")
	dst2 := filepath.Join(ts.dir, "destination2.txt")

	req := &pb.InstallInfoRequest{
		InstallId: "//test:partial",
		Files:     map[string]string{dst1: src1, dst2: src2},
	}
	if _, err := ts.Install(context.Background(), req); err != nil {
		t.Fatalf("Install failed: %v", err)
	}

	// complete only the first file
	if _, err := ts.FileReady(context.Background(), &pb.FileReadyRequest{
		InstallId: "//test:partial", Name: dst1, Path: src1,
	}); err != nil {
		t.Fatalf("FileReady failed: %v", err)
	}

	if _, err := os.Lstat(dst1); err != nil {
		t.Error("symlink should exist after FileReady")
	}
	if _, err := os.Lstat(dst2); !os.IsNotExist(err) {
		t.Error("second symlink should not exist yet")
	}

	installs, err := ts.store.GetInstalls()
	if err != nil {
		t.Fatalf("GetInstalls failed: %v", err)
	}
	for _, install := range installs {
		if install.InstallID == "//test:partial" {
			t.Error("install should not be logged until all files complete")
		}
	}
}

func TestFileReady_AtomicCommit(t *testing.T) {
	ts := newTestServer(t)
	src := ts.writeFile(t, "source.txt", "test")
	dst := filepath.Join(ts.dir, "destination.txt")

	ts.install(t, "//test:atomic", map[string]string{dst: src})

	if _, err := os.Lstat(dst); os.IsNotExist(err) {
		t.Error("symlink should exist after complete install")
	}

	installs, err := ts.store.GetInstalls()
	if err != nil {
		t.Fatalf("GetInstalls failed: %v", err)
	}
	found := false
	for _, install := range installs {
		if install.InstallID == "//test:atomic" {
			found = true
			break
		}
	}
	if !found {
		t.Error("install should be logged after completion")
	}
}

func TestFileReady_CreatesGCRoots(t *testing.T) {
	ts := newTestServer(t)
	src := ts.writeFile(t, "source.txt", "test")
	dst := filepath.Join(ts.dir, "destination.txt")

	ts.install(t, "//test:gcroots", map[string]string{dst: src})

	roots, err := ts.store.GetRoots()
	if err != nil {
		t.Fatalf("GetRoots failed: %v", err)
	}
	if len(roots) == 0 {
		t.Fatal("expected at least one GC root to be created")
	}

	found := false
	for _, root := range roots {
		if root.InstallID == "//test:gcroots" {
			found = true
			if root.SymlinkPath != dst {
				t.Errorf("expected symlink path %s, got %s", dst, root.SymlinkPath)
			}
		}
	}
	if !found {
		t.Error("GC root for install not found")
	}
}

func TestFileReady_TracksStartedAndCompleted(t *testing.T) {
	ts := newTestServer(t)
	src := ts.writeFile(t, "source.txt", "test")
	dst := filepath.Join(ts.dir, "destination.txt")

	// register install but don't complete any files yet
	req := &pb.InstallInfoRequest{
		InstallId: "//test:tracking",
		Files:     map[string]string{dst: src},
	}
	if _, err := ts.Install(context.Background(), req); err != nil {
		t.Fatalf("Install failed: %v", err)
	}

	installs, err := ts.store.GetInstalls()
	if err != nil {
		t.Fatalf("GetInstalls failed: %v", err)
	}
	for _, install := range installs {
		if install.InstallID == "//test:tracking" {
			t.Error("install should not be logged before FileReady completes")
		}
	}

	if _, err := ts.FileReady(context.Background(), &pb.FileReadyRequest{
		InstallId: "//test:tracking", Name: dst, Path: src,
	}); err != nil {
		t.Fatalf("FileReady failed: %v", err)
	}

	installs, err = ts.store.GetInstalls()
	if err != nil {
		t.Fatalf("GetInstalls failed: %v", err)
	}
	found := false
	for _, install := range installs {
		if install.InstallID == "//test:tracking" {
			found = true
			break
		}
	}
	if !found {
		t.Error("install should be logged after FileReady completes")
	}
}
