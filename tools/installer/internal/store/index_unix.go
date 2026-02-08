//go:build unix

package store

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// mmapIndex memory-maps the index.
func mmapIndex(f *os.File, size int64) ([]byte, error) {
	if size == 0 {
		return nil, nil
	}

	mmap, err := unix.Mmap(
		int(f.Fd()),
		0,
		int(size),
		unix.PROT_READ|unix.PROT_WRITE,
		unix.MAP_SHARED,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to mmap index: %w", err)
	}

	return mmap, nil
}

// munmapIndex unmaps the index.
func munmapIndex(mmap []byte) error {
	if len(mmap) == 0 {
		return nil
	}

	if err := unix.Munmap(mmap); err != nil {
		return fmt.Errorf("failed to munmap index: %w", err)
	}

	return nil
}

// lockShared acquires a shared lock on the specified lock byte within a slot.
func (idx *Index) lockShared(slot int, lockNum int) error {
	offset := int64(slot*slotSize + lockNum)

	flock := unix.Flock_t{
		Type:   unix.F_RDLCK,
		Whence: unix.SEEK_SET,
		Start:  offset,
		Len:    1,
	}

	if err := unix.FcntlFlock(idx.f.Fd(), F_OFD_SETLKW, &flock); err != nil {
		return fmt.Errorf(
			"failed to acquire shared lock on slot %d lock %d: %w", slot, lockNum, err,
		)
	}

	return nil
}

// lockExclusive acquires an exclusive lock on the specified lock byte within a
// slot.
func (idx *Index) lockExclusive(slot int, lockNum int) error {
	offset := int64(slot*slotSize + lockNum)

	flock := unix.Flock_t{
		Type:   unix.F_WRLCK,
		Whence: unix.SEEK_SET,
		Start:  offset,
		Len:    1,
	}

	if err := unix.FcntlFlock(idx.f.Fd(), F_OFD_SETLKW, &flock); err != nil {
		return fmt.Errorf(
			"failed to acquire exclusive lock on slot %d lock %d: %w", slot, lockNum, err,
		)
	}

	return nil
}

// unlock releases the lock on the specified lock byte within a slot.
func (idx *Index) unlock(slot int, lockNum int) error {
	offset := int64(slot*slotSize + lockNum)

	flock := unix.Flock_t{
		Type:   unix.F_UNLCK,
		Whence: unix.SEEK_SET,
		Start:  offset,
		Len:    1,
	}

	if err := unix.FcntlFlock(idx.f.Fd(), F_OFD_SETLK, &flock); err != nil {
		return fmt.Errorf(
			"failed to release lock on slot %d lock %d: %w", slot, lockNum, err,
		)
	}

	return nil
}
