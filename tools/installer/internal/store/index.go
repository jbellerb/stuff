package store

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"sync/atomic"
	"unsafe"
)

const slotSize = 16

// Index manages concurrent access to files. Each log file gets a slot in the
// index with independent locks.
type Index struct {
	f    *os.File
	mmap []byte
}

// OpenIndex opens or creates an index for the given number of slots.
func OpenIndex(indexPath string, slotCount int) (*Index, error) {
	requiredSize := int64(slotCount * slotSize)

	f, err := os.OpenFile(indexPath, os.O_RDWR|os.O_CREATE, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open index: %w", err)
	}

	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, fmt.Errorf("failed to stat index: %w", err)
	}
	if info.Size() < requiredSize {
		if err := f.Truncate(requiredSize); err != nil {
			f.Close()
			return nil, fmt.Errorf("failed to extend index: %w", err)
		}
	}

	mmap, err := mmapIndex(f, requiredSize)
	if err != nil {
		f.Close()
		return nil, err
	}

	return &Index{f: f, mmap: mmap}, nil
}

// Close closes the index.
func (idx *Index) Close() error {
	if err := munmapIndex(idx.mmap); err != nil {
		idx.f.Close()
		return err
	}

	return idx.f.Close()
}

// Log returns a LogIndex for the given slot.
func (idx *Index) Log(slot int, logPath string) *LogIndex {
	return &LogIndex{
		idx:     idx,
		slot:    slot,
		logPath: logPath,
	}
}

// LogIndex coordinates access to a single log file through a slot in the shared
// index. All operations are thread-safe and support concurrent access by
// multiple readers.
type LogIndex struct {
	idx     *Index
	slot    int
	logPath string
}

// ReadTx is a read-only transaction over a snapshot of a log file.
type ReadTx interface {
	io.ReadSeekCloser
}

// BeginReadTx opens a read-only transaction over a snapshot of the log file.
// The snapshotted portion is immutable while the reader is open.
func (l *LogIndex) BeginReadTx() (ReadTx, error) {
	if err := l.ensureInitialized(); err != nil {
		return nil, err
	}

	// take shared lock on read byte (lock 0)
	if err := l.idx.lockShared(l.slot, 0); err != nil {
		return nil, fmt.Errorf("failed to acquire read lock: %w", err)
	}
	len := l.snapshotLength()

	f, err := os.Open(l.logPath)
	if err != nil {
		l.idx.unlock(l.slot, 0)
		return nil, fmt.Errorf("failed to open log file: %w", err)
	}

	return &windowReader{
		f:      f,
		unlock: func() error { return l.idx.unlock(l.slot, 0) },
		len:    len,
	}, nil
}

// AppendTx is an append-only transaction on a log file.
type AppendTx interface {
	io.WriteCloser
}

// BeginAppendTx opens an append-only transaction on the log file. The append is
// committed on close.
func (l *LogIndex) BeginAppendTx() (AppendTx, error) {
	if err := l.ensureInitialized(); err != nil {
		return nil, err
	}

	// take exclusive lock on write byte (lock 1)
	if err := l.idx.lockExclusive(l.slot, 1); err != nil {
		return nil, fmt.Errorf("failed to acquire write lock: %w", err)
	}

	f, err := os.OpenFile(l.logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0644)
	if err != nil {
		l.idx.unlock(l.slot, 1)
		return nil, fmt.Errorf("failed to open log file: %w", err)
	}

	return &appendWriter{
		f:   f,
		log: l,
	}, nil
}

// WriteTx is a read/write transaction on a log file with exclusive access.
type WriteTx interface {
	io.ReadSeekCloser
	io.Writer
	Truncate(size int64) error
}

// BeginWriteTx opens a read/write transaction on the log file. During the
// transaction, the writer has exclusive access to the log file.
func (l *LogIndex) BeginWriteTx() (WriteTx, error) {
	if err := l.ensureInitialized(); err != nil {
		return nil, err
	}

	// take exclusive locks on both bytes
	if err := l.idx.lockExclusive(l.slot, 1); err != nil {
		return nil, fmt.Errorf("failed to acquire write lock: %w", err)
	}
	if err := l.idx.lockExclusive(l.slot, 0); err != nil {
		l.idx.unlock(l.slot, 1)
		return nil, fmt.Errorf("failed to acquire read lock: %w", err)
	}

	f, err := os.OpenFile(l.logPath, os.O_RDWR|os.O_CREATE, 0644)
	if err != nil {
		l.idx.unlock(l.slot, 1)
		l.idx.unlock(l.slot, 0)
		return nil, fmt.Errorf("failed to open log file: %w", err)
	}

	return &fullWriter{
		f:   f,
		log: l,
	}, nil
}

// ensureInitialized writes the log file's current size as the committed length
// if the slot has not yet been initialized.
func (l *LogIndex) ensureInitialized() error {
	// Fast path: if committed length is already set, return
	if l.snapshotLength() != 0 {
		return nil
	}

	// take exclusive write lock to initialize
	if err := l.idx.lockExclusive(l.slot, 1); err != nil {
		return fmt.Errorf("failed to acquire initialization lock: %w", err)
	}
	defer l.idx.unlock(l.slot, 1)

	// double-check in case we raced with another thread that updated it first
	if l.snapshotLength() != 0 {
		return nil
	}

	logInfo, err := os.Stat(l.logPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to stat log file: %w", err)
	} else if err == nil && logInfo.Size() > 0 {
		l.writeLength(logInfo.Size())
	}

	return nil
}

// snapshotLength atomically reads the committed length from the index slot.
func (l *LogIndex) snapshotLength() int64 {
	offset := l.slot*slotSize + 8
	ptr := (*uint64)(unsafe.Pointer(&l.idx.mmap[offset]))
	return int64(atomic.LoadUint64(ptr))
}

// writeLength atomically writes the committed length to the index slot.
func (l *LogIndex) writeLength(length int64) {
	offset := l.slot*slotSize + 8
	ptr := (*uint64)(unsafe.Pointer(&l.idx.mmap[offset]))
	atomic.StoreUint64(ptr, uint64(length))
}

// windowReader implements io.ReadSeekCloser for a range within a file.
type windowReader struct {
	f      *os.File
	unlock func() error
	pos    int64

	offset, len int64
}

var _ ReadTx = &windowReader{}

// Close implements io.Closer.
func (w *windowReader) Close() error {
	err1 := w.f.Close()
	err2 := w.unlock()
	if err1 != nil {
		return err1
	}
	return err2
}

// Read implements io.Reader.
func (w *windowReader) Read(p []byte) (n int, err error) {
	remaining := w.len - w.pos
	if remaining <= 0 {
		return 0, io.EOF
	} else if int64(len(p)) > remaining {
		p = p[:remaining]
	}

	n, err = w.f.Read(p)
	if err == nil {
		w.pos += int64(n)
	}

	return n, err
}

// Seek implements io.Seeker.
func (w *windowReader) Seek(offset int64, whence int) (int64, error) {
	var pos int64
	switch whence {
	case io.SeekStart:
		pos = offset
	case io.SeekCurrent:
		pos = w.pos + offset
	case io.SeekEnd:
		pos = w.len + offset
	default:
		return 0, fs.ErrInvalid
	}

	if pos < 0 || pos > w.len {
		return 0, fs.ErrInvalid
	}

	n, err := w.f.Seek(pos+w.offset, io.SeekStart)
	if err == nil {
		w.pos = pos
	}

	return n - w.offset, err
}

// appendWriter implements io.WriteCloser for append-only transactions.
type appendWriter struct {
	f   *os.File
	log *LogIndex
}

var _ AppendTx = &appendWriter{}

// Close implements io.Closer.
func (w *appendWriter) Close() error {
	info, err := w.f.Stat()
	if err != nil {
		w.f.Close()
		w.log.idx.unlock(w.log.slot, 1)
		return fmt.Errorf("failed to stat file: %w", err)
	}

	w.log.writeLength(info.Size())

	err1 := w.f.Close()
	err2 := w.log.idx.unlock(w.log.slot, 1)
	if err1 != nil {
		return err1
	}
	return err2
}

// Write implements io.Writer.
func (w *appendWriter) Write(p []byte) (n int, err error) {
	return w.f.Write(p)
}

// fullWriter implements WriteTx for full read/write transactions.
type fullWriter struct {
	f   *os.File
	log *LogIndex
}

var _ WriteTx = &fullWriter{}

// Read implements io.Reader.
func (w *fullWriter) Read(p []byte) (n int, err error) {
	return w.f.Read(p)
}

// Write implements io.Writer.
func (w *fullWriter) Write(p []byte) (n int, err error) {
	return w.f.Write(p)
}

// Seek implements io.Seeker.
func (w *fullWriter) Seek(offset int64, whence int) (int64, error) {
	return w.f.Seek(offset, whence)
}

// Truncate truncates the file to the specified size.
func (w *fullWriter) Truncate(size int64) error {
	return w.f.Truncate(size)
}

// Close commits the transaction by updating the index with the new length.
func (w *fullWriter) Close() error {
	info, err := w.f.Stat()
	if err != nil {
		w.f.Close()
		w.log.idx.unlock(w.log.slot, 1)
		w.log.idx.unlock(w.log.slot, 0)
		return fmt.Errorf("failed to stat file: %w", err)
	}

	w.log.writeLength(info.Size())

	err1 := w.f.Close()
	err2 := w.log.idx.unlock(w.log.slot, 1)
	err3 := w.log.idx.unlock(w.log.slot, 0)
	if err1 != nil {
		return err1
	} else if err2 != nil {
		return err2
	}

	return err3
}
