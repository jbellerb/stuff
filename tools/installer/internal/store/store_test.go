package store

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()

	tempDir := t.TempDir()
	st, err := NewStore(tempDir)
	if err != nil {
		t.Fatalf("NewStore failed: %v", err)
	}

	return st
}

type testLog struct {
	*LogIndex
	dir       string
	indexPath string
	logPath   string
}

func newTestLog(t *testing.T, content []byte) testLog {
	t.Helper()

	dir := t.TempDir()
	indexPath := filepath.Join(dir, ".index")
	logPath := filepath.Join(dir, "test.log")

	if content != nil {
		if err := os.WriteFile(logPath, content, 0644); err != nil {
			t.Fatalf("failed to create log file: %v", err)
		}
	}

	idx, err := OpenIndex(indexPath, 1)
	if err != nil {
		t.Fatalf("OpenIndex failed: %v", err)
	}
	t.Cleanup(func() { idx.Close() })

	return testLog{
		LogIndex:  idx.Log(0, logPath),
		dir:       dir,
		indexPath: indexPath,
		logPath:   logPath,
	}
}

func (tl *testLog) committedLength(t *testing.T) int64 {
	t.Helper()

	f, err := os.Open(tl.indexPath)
	if err != nil {
		t.Fatalf("failed to open index: %v", err)
	}
	defer f.Close()

	var buf [8]byte
	if _, err := f.ReadAt(buf[:], 8); err != nil {
		t.Fatalf("failed to read committed length: %v", err)
	}
	return int64(binary.LittleEndian.Uint64(buf[:]))
}

func TestNewStore_CreatesObjectsDirectory(t *testing.T) {
	st := newTestStore(t)

	objectsDir := filepath.Join(st.path, "objects")
	if _, err := os.Stat(objectsDir); os.IsNotExist(err) {
		t.Error("objects directory was not created")
	}
}

func TestStore_Put_AddsFile(t *testing.T) {
	st := newTestStore(t)
	tempDir := t.TempDir()

	sourceFile := filepath.Join(tempDir, "source.txt")
	content := []byte("test content")
	if err := os.WriteFile(sourceFile, content, 0644); err != nil {
		t.Fatalf("failed to create source file: %v", err)
	}

	digest, err := st.Put(sourceFile)
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	if digest == "" {
		t.Error("expected non-empty digest")
	}

	// verify object exists in store
	objectPath := st.ObjectPath(digest)
	if _, err := os.Stat(objectPath); os.IsNotExist(err) {
		t.Error("object was not created in store")
	}

	// verify content
	storedContent, err := os.ReadFile(objectPath)
	if err != nil {
		t.Fatalf("failed to read stored object: %v", err)
	}

	if string(storedContent) != string(content) {
		t.Errorf("content mismatch: expected %q, got %q", content, storedContent)
	}
}

func TestStore_Put_Deduplicates(t *testing.T) {
	st := newTestStore(t)
	tempDir := t.TempDir()

	content := []byte("same content")

	file1 := filepath.Join(tempDir, "file1.txt")
	file2 := filepath.Join(tempDir, "file2.txt")
	if err := os.WriteFile(file1, content, 0644); err != nil {
		t.Fatalf("failed to create file1: %v", err)
	}
	if err := os.WriteFile(file2, content, 0644); err != nil {
		t.Fatalf("failed to create file2: %v", err)
	}

	digest1, err := st.Put(file1)
	if err != nil {
		t.Fatalf("Put(file1) failed: %v", err)
	}

	digest2, err := st.Put(file2)
	if err != nil {
		t.Fatalf("Put(file2) failed: %v", err)
	}

	if digest1 != digest2 {
		t.Errorf("expected same digest, got %s and %s", digest1, digest2)
	}

	// verify only one object exists
	entries, err := os.ReadDir(st.StorePath())
	if err != nil {
		t.Fatalf("failed to read objects directory: %v", err)
	}

	if len(entries) != 1 {
		t.Errorf("expected 1 object, got %d", len(entries))
	}
}

func TestStore_CompleteInstall(t *testing.T) {
	st := newTestStore(t)
	tempDir := t.TempDir()

	sourceFile := filepath.Join(tempDir, "test.txt")
	if err := os.WriteFile(sourceFile, []byte("content"), 0644); err != nil {
		t.Fatalf("failed to create source file: %v", err)
	}

	digest, err := st.Put(sourceFile)
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	symlinkPath := filepath.Join(tempDir, "link.txt")
	objectPath := st.ObjectPath(digest)
	if err := os.Symlink(objectPath, symlinkPath); err != nil {
		t.Fatalf("failed to create symlink: %v", err)
	}
	if err := st.CreateRoot("//test:target", symlinkPath, digest); err != nil {
		t.Fatalf("failed to create gc root: %v", err)
	}

	files := map[string]string{"link.txt": digest}
	if err := st.CommitInstall("//test:target", files); err != nil {
		t.Fatalf("CompleteInstall failed: %v", err)
	}

	// verify install was logged
	installs, err := st.GetInstalls()
	if err != nil {
		t.Fatalf("GetInstalls failed: %v", err)
	}
	if len(installs) != 1 {
		t.Fatalf("expected 1 install, got %d", len(installs))
	}

	install := installs[0]
	if install.InstallID != "//test:target" {
		t.Errorf("expected InstallID //test:target, got %s", install.InstallID)
	}
	if len(install.Files) != 1 {
		t.Errorf("expected 1 file, got %d", len(install.Files))
	}
	if install.Files["link.txt"] != digest {
		t.Errorf("expected digest %s, got %s", digest, install.Files["link.txt"])
	}

	// verify GC roots were logged
	gcRoots, err := st.GetRoots()
	if err != nil {
		t.Fatalf("GetRoots failed: %v", err)
	}
	if len(gcRoots) != 1 {
		t.Fatalf("expected 1 root, got %d", len(gcRoots))
	}

	root := gcRoots[0]
	if root.InstallID != "//test:target" {
		t.Errorf("expected InstallID //test:target, got %s", root.InstallID)
	}
	if root.SymlinkPath != symlinkPath {
		t.Errorf("expected SymlinkPath %s, got %s", symlinkPath, root.SymlinkPath)
	}
}

func TestStore_GC_RemovesUnreferencedObjects(t *testing.T) {
	st := newTestStore(t)
	tempDir := t.TempDir()

	file1 := filepath.Join(tempDir, "file1.txt")
	file2 := filepath.Join(tempDir, "file2.txt")
	if err := os.WriteFile(file1, []byte("content1"), 0644); err != nil {
		t.Fatalf("failed to create file1: %v", err)
	}
	if err := os.WriteFile(file2, []byte("content2"), 0644); err != nil {
		t.Fatalf("failed to create file2: %v", err)
	}

	digest1, _ := st.Put(file1)
	digest2, _ := st.Put(file2)

	// create symlink for only file1
	symlinkPath := filepath.Join(tempDir, "link.txt")
	if err := os.Symlink(st.ObjectPath(digest1), symlinkPath); err != nil {
		t.Fatalf("failed to create symlink: %v", err)
	}

	// create root and log install with only file1
	if err := st.CreateRoot("//test:target", symlinkPath, digest1); err != nil {
		t.Fatalf("failed to create root: %v", err)
	}
	files := map[string]string{"link.txt": digest1}
	if err := st.CommitInstall("//test:target", files); err != nil {
		t.Fatalf("failed to commit install: %v", err)
	}

	if err := st.GC(); err != nil {
		t.Fatalf("GC failed: %v", err)
	}

	// verify file1 still exists
	if _, err := os.Stat(st.ObjectPath(digest1)); err != nil {
		t.Error("referenced object was deleted")
	}

	// verify file2 was deleted
	if _, err := os.Stat(st.ObjectPath(digest2)); !os.IsNotExist(err) {
		t.Error("unreferenced object was not deleted")
	}
}

func TestStore_GC_RemovesDeadRoots(t *testing.T) {
	st := newTestStore(t)
	tempDir := t.TempDir()

	sourceFile := filepath.Join(tempDir, "test.txt")
	if err := os.WriteFile(sourceFile, []byte("content"), 0644); err != nil {
		t.Fatalf("failed to create source file: %v", err)
	}

	digest, _ := st.Put(sourceFile)

	symlinkPath := filepath.Join(tempDir, "link.txt")
	objectPath := st.ObjectPath(digest)
	if err := os.Symlink(objectPath, symlinkPath); err != nil {
		t.Fatalf("failed to create symlink: %v", err)
	}

	if err := st.CreateRoot("//test:target", symlinkPath, digest); err != nil {
		t.Fatalf("failed to create root: %v", err)
	}
	files := map[string]string{"link.txt": digest}
	if err := st.CommitInstall("//test:target", files); err != nil {
		t.Fatalf("failed to commit install: %v", err)
	}

	// remove symlink to make root dead
	os.Remove(symlinkPath)

	if err := st.GC(); err != nil {
		t.Fatalf("GC failed: %v", err)
	}

	// verify root was removed
	gcRoots, err := st.GetRoots()
	if err != nil {
		t.Fatalf("GetRoots failed: %v", err)
	}

	if len(gcRoots) != 0 {
		t.Errorf("expected 0 roots after GC, got %d", len(gcRoots))
	}

	// verify install was removed
	installs, err := st.GetInstalls()
	if err != nil {
		t.Fatalf("GetInstalls failed: %v", err)
	}

	if len(installs) != 0 {
		t.Errorf("expected 0 installs after GC, got %d", len(installs))
	}

	// verify object was deleted
	if _, err := os.Stat(objectPath); !os.IsNotExist(err) {
		t.Error("object was not deleted after root died")
	}
}

func TestStore_GC_KeepsNewerRoots(t *testing.T) {
	tempDir := t.TempDir()
	st, err := NewStore(tempDir)
	if err != nil {
		t.Fatalf("NewStore failed: %v", err)
	}

	file1 := filepath.Join(tempDir, "file1.txt")
	file2 := filepath.Join(tempDir, "file2.txt")
	if err := os.WriteFile(file1, []byte("old content"), 0644); err != nil {
		t.Fatalf("failed to create file1: %v", err)
	}
	if err := os.WriteFile(file2, []byte("new content"), 0644); err != nil {
		t.Fatalf("failed to create file2: %v", err)
	}

	digest1, _ := st.Put(file1)
	digest2, _ := st.Put(file2)

	// create symlink pointing to file1 initially
	symlinkPath := filepath.Join(tempDir, "link.txt")
	if err := os.Symlink(st.ObjectPath(digest1), symlinkPath); err != nil {
		t.Fatalf("failed to create symlink: %v", err)
	}

	// log old install
	if err := st.CreateRoot("//test:old", symlinkPath, digest1); err != nil {
		t.Fatalf("failed to create old root: %v", err)
	}
	if err := st.CommitInstall("//test:old", map[string]string{"link.txt": digest1}); err != nil {
		t.Fatalf("failed to commit old install: %v", err)
	}

	time.Sleep(10 * time.Millisecond)

	// update symlink to point to file2
	os.Remove(symlinkPath)
	if err := os.Symlink(st.ObjectPath(digest2), symlinkPath); err != nil {
		t.Fatalf("failed to create new symlink: %v", err)
	}

	// log new install
	if err := st.CreateRoot("//test:new", symlinkPath, digest2); err != nil {
		t.Fatalf("failed to create new root: %v", err)
	}
	if err := st.CommitInstall("//test:new", map[string]string{"link.txt": digest2}); err != nil {
		t.Fatalf("failed to commit new install: %v", err)
	}

	if err := st.GC(); err != nil {
		t.Fatalf("GC failed: %v", err)
	}

	// verify only newer root is kept
	gcRoots, err := st.GetRoots()
	if err != nil {
		t.Fatalf("GetRoots failed: %v", err)
	}

	if len(gcRoots) != 1 {
		t.Fatalf("expected 1 root after GC, got %d", len(gcRoots))
	}

	if gcRoots[0].InstallID != "//test:new" {
		t.Errorf("expected newer root to be kept, got %s", gcRoots[0].InstallID)
	}

	// verify only new install is kept
	installs, err := st.GetInstalls()
	if err != nil {
		t.Fatalf("GetInstalls failed: %v", err)
	}

	if len(installs) != 1 {
		t.Fatalf("expected 1 install after GC, got %d", len(installs))
	}

	if installs[0].InstallID != "//test:new" {
		t.Errorf("expected new install to be kept, got %s", installs[0].InstallID)
	}
}

func TestIndex_InitializesSlots(t *testing.T) {
	tl := newTestLog(t, []byte("initial content"))

	r, err := tl.BeginReadTx()
	if err != nil {
		t.Fatalf("BeginReadTx failed: %v", err)
	}
	defer r.Close()

	if committedLen := tl.committedLength(t); committedLen != 15 {
		t.Errorf("expected committed length 15, got %d", committedLen)
	}
}

func TestIndex_ConcurrentReads(t *testing.T) {
	tl := newTestLog(t, []byte("test data"))

	var wg sync.WaitGroup
	for range 10 {
		wg.Go(func() {
			r, err := tl.BeginReadTx()
			if err != nil {
				t.Errorf("BeginReadTx failed: %v", err)
				return
			}
			defer r.Close()

			data, err := io.ReadAll(r)
			if err != nil {
				t.Errorf("ReadAll failed: %v", err)
				return
			}

			if string(data) != "test data" {
				t.Errorf("expected 'test data', got %q", string(data))
			}
		})
	}

	wg.Wait()
}

func TestIndex_AppendUpdatesCommittedLength(t *testing.T) {
	tl := newTestLog(t, nil)

	w, err := tl.BeginAppendTx()
	if err != nil {
		t.Fatalf("BeginAppendTx failed: %v", err)
	}
	w.Write([]byte("first write\n"))
	if err := w.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}
	if committedLen := tl.committedLength(t); committedLen != 12 {
		t.Errorf("expected committed length 12, got %d", committedLen)
	}

	w, err = tl.BeginAppendTx()
	if err != nil {
		t.Fatalf("BeginAppendTx failed: %v", err)
	}
	w.Write([]byte("second write\n"))
	if err := w.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}
	if committedLen := tl.committedLength(t); committedLen != 25 {
		t.Errorf("expected committed length 25, got %d", committedLen)
	}

	// verify a reader sees all committed data
	r, err := tl.BeginReadTx()
	if err != nil {
		t.Fatalf("BeginReadTx failed: %v", err)
	}
	defer r.Close()

	data, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("ReadAll failed: %v", err)
	}

	if string(data) != "first write\nsecond write\n" {
		t.Errorf("unexpected data: %q", string(data))
	}
}

func TestIndex_ReadersGetSnapshot(t *testing.T) {
	tl := newTestLog(t, []byte("initial"))

	r, err := tl.BeginReadTx()
	if err != nil {
		t.Fatalf("BeginReadTx failed: %v", err)
	}
	defer r.Close()

	// append more data while reader is open
	w, err := tl.BeginAppendTx()
	if err != nil {
		t.Fatalf("BeginAppendTx failed: %v", err)
	}
	w.Write([]byte(" appended"))
	if err := w.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}

	// verify reader only sees initial snapshot
	data, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("ReadAll failed: %v", err)
	}
	if string(data) != "initial" {
		t.Errorf("expected 'initial', got %q", string(data))
	}

	// new reader should see updated data
	r2, err := tl.BeginReadTx()
	if err != nil {
		t.Fatalf("BeginReadTx failed: %v", err)
	}
	defer r2.Close()

	data2, err := io.ReadAll(r2)
	if err != nil {
		t.Fatalf("ReadAll failed: %v", err)
	}
	if string(data2) != "initial appended" {
		t.Errorf("expected 'initial appended', got %q", string(data2))
	}
}

func TestIndex_WriteTxTruncatesAndRewrites(t *testing.T) {
	tl := newTestLog(t, []byte("old data that is long"))

	w, err := tl.BeginWriteTx()
	if err != nil {
		t.Fatalf("BeginWriteTx failed: %v", err)
	}

	if err := w.Truncate(0); err != nil {
		t.Fatalf("Truncate failed: %v", err)
	}
	w.Write([]byte("new"))
	if err := w.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}

	if committedLen := tl.committedLength(t); committedLen != 3 {
		t.Errorf("expected committed length 3, got %d", committedLen)
	}

	data, _ := os.ReadFile(tl.logPath)
	if string(data) != "new" {
		t.Errorf("expected 'new', got %q", string(data))
	}
}

func TestIndex_MultipleSlots(t *testing.T) {
	tempDir := t.TempDir()
	indexPath := filepath.Join(tempDir, ".index")
	log1Path := filepath.Join(tempDir, "log1.log")
	log2Path := filepath.Join(tempDir, "log2.log")

	idx, err := OpenIndex(indexPath, 2)
	if err != nil {
		t.Fatalf("OpenIndex failed: %v", err)
	}
	defer idx.Close()

	log1 := idx.Log(0, log1Path)
	log2 := idx.Log(1, log2Path)

	w1, _ := log1.BeginAppendTx()
	w1.Write([]byte("log1 data"))
	w1.Close()

	w2, _ := log2.BeginAppendTx()
	w2.Write([]byte("log2 data"))
	w2.Close()

	// verify both committed lengths
	f, _ := os.Open(indexPath)
	var buf [8]byte

	f.ReadAt(buf[:], 8) // slot 0
	len1 := int64(binary.LittleEndian.Uint64(buf[:]))

	f.ReadAt(buf[:], 24) // slot 1
	len2 := int64(binary.LittleEndian.Uint64(buf[:]))
	f.Close()

	if len1 != 9 {
		t.Errorf("expected slot 0 committed length 9, got %d", len1)
	}
	if len2 != 9 {
		t.Errorf("expected slot 1 committed length 9, got %d", len2)
	}
}

func TestIndex_ConcurrentReadersAndWriters(t *testing.T) {
	tl := newTestLog(t, []byte(""))

	var wg sync.WaitGroup
	errors := make(chan error, 20)

	for i := range 5 {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			w, err := tl.BeginAppendTx()
			if err != nil {
				errors <- fmt.Errorf("BeginAppendTx failed: %w", err)
				return
			}

			data := fmt.Sprintf("write %d\n", n)
			if _, err := w.Write([]byte(data)); err != nil {
				errors <- fmt.Errorf("Write failed: %w", err)
				return
			}

			if err := w.Close(); err != nil {
				errors <- fmt.Errorf("Close failed: %w", err)
			}
		}(i)
	}

	for range 15 {
		wg.Go(func() {
			r, err := tl.BeginReadTx()
			if err != nil {
				errors <- fmt.Errorf("BeginReadTx failed: %w", err)
				return
			}
			defer r.Close()

			if _, err := io.ReadAll(r); err != nil {
				errors <- fmt.Errorf("ReadAll failed: %w", err)
			}
		})
	}

	wg.Wait()
	close(errors)

	for err := range errors {
		t.Error(err)
	}

	data, _ := os.ReadFile(tl.logPath)
	if len(data) != 40 { // 5 writes of "write N\n" (8 bytes each)
		t.Errorf("expected 40 bytes written, got %d", len(data))
	}
}

func TestIndex_ReadNonexistentLog(t *testing.T) {
	dir := t.TempDir()
	indexPath := filepath.Join(dir, ".index")
	logPath := filepath.Join(dir, "nonexistent.log")

	idx, err := OpenIndex(indexPath, 1)
	if err != nil {
		t.Fatalf("OpenIndex failed: %v", err)
	}
	defer idx.Close()

	_, err = idx.Log(0, logPath).BeginReadTx()
	if err == nil {
		t.Fatal("expected error for nonexistent log, got nil")
	}
}

func TestIndex_ReadEmptyLog(t *testing.T) {
	tl := newTestLog(t, []byte{})

	r, err := tl.BeginReadTx()
	if err != nil {
		t.Fatalf("BeginReadTx failed: %v", err)
	}
	defer r.Close()

	data, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("ReadAll failed: %v", err)
	}
	if len(data) != 0 {
		t.Errorf("expected empty read, got %q", data)
	}
}

func TestIndex_WriteTxExcludesReaders(t *testing.T) {
	tempDir := t.TempDir()
	indexPath := filepath.Join(tempDir, ".index")
	logPath := filepath.Join(tempDir, "test.log")

	if err := os.WriteFile(logPath, []byte("data"), 0644); err != nil {
		t.Fatalf("failed to create log file: %v", err)
	}

	// use two separate Index instances to simulate two processes
	writerIdx, err := OpenIndex(indexPath, 1)
	if err != nil {
		t.Fatalf("OpenIndex (writer) failed: %v", err)
	}
	defer writerIdx.Close()

	readerIdx, err := OpenIndex(indexPath, 1)
	if err != nil {
		t.Fatalf("OpenIndex (reader) failed: %v", err)
	}
	defer readerIdx.Close()

	w, err := writerIdx.Log(0, logPath).BeginWriteTx()
	if err != nil {
		t.Fatalf("BeginWriteTx failed: %v", err)
	}

	// read from different file descriptor should block
	readerStarted := make(chan struct{})
	readerDone := make(chan struct{})
	go func() {
		close(readerStarted)
		r, err := readerIdx.Log(0, logPath).BeginReadTx()
		if err != nil {
			t.Errorf("BeginReadTx failed: %v", err)
			close(readerDone)
			return
		}
		r.Close()
		close(readerDone)
	}()

	<-readerStarted
	time.Sleep(50 * time.Millisecond)

	select {
	case <-readerDone:
		t.Error("reader should be blocked while write tx is open")
	default:
	}

	w.Close()

	select {
	case <-readerDone:
	case <-time.After(2 * time.Second):
		t.Error("reader did not unblock after write tx closed")
	}
}

func TestIndex_WindowReaderSeek(t *testing.T) {
	tl := newTestLog(t, []byte("hello world"))

	r, err := tl.BeginReadTx()
	if err != nil {
		t.Fatalf("BeginReadTx failed: %v", err)
	}
	defer r.Close()

	buf := make([]byte, 5)
	n, err := r.Read(buf)
	if err != nil {
		t.Fatalf("Read failed: %v", err)
	}
	if string(buf[:n]) != "hello" {
		t.Errorf("expected 'hello', got %q", buf[:n])
	}

	// SeekStart to beginning
	pos, err := r.Seek(0, io.SeekStart)
	if err != nil {
		t.Fatalf("Seek(0, SeekStart) failed: %v", err)
	}
	if pos != 0 {
		t.Errorf("expected pos 0, got %d", pos)
	}

	n, err = r.Read(buf)
	if err != nil {
		t.Fatalf("Read after SeekStart failed: %v", err)
	}
	if string(buf[:n]) != "hello" {
		t.Errorf("expected 'hello', got %q", buf[:n])
	}

	// SeekCurrent forward 1
	pos, err = r.Seek(1, io.SeekCurrent)
	if err != nil {
		t.Fatalf("Seek(1, SeekCurrent) failed: %v", err)
	}
	if pos != 6 {
		t.Errorf("expected pos 6, got %d", pos)
	}

	n, err = r.Read(buf)
	if err != nil {
		t.Fatalf("Read after SeekCurrent failed: %v", err)
	}
	if string(buf[:n]) != "world" {
		t.Errorf("expected 'world', got %q", buf[:n])
	}

	// SeekEnd to last 5 bytes
	pos, err = r.Seek(-5, io.SeekEnd)
	if err != nil {
		t.Fatalf("Seek(-5, SeekEnd) failed: %v", err)
	}
	if pos != 6 {
		t.Errorf("expected pos 6, got %d", pos)
	}

	n, err = r.Read(buf)
	if err != nil {
		t.Fatalf("Read after SeekEnd failed: %v", err)
	}
	if string(buf[:n]) != "world" {
		t.Errorf("expected 'world', got %q", buf[:n])
	}

	// verify seek past end fails
	_, err = r.Seek(1, io.SeekEnd)
	if err == nil {
		t.Error("expected error seeking past end")
	}

	// verify seek before start fails
	_, err = r.Seek(-1, io.SeekStart)
	if err == nil {
		t.Error("expected error seeking before start")
	}
}
