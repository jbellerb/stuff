package store

import (
	"golang.org/x/sys/unix"
)

// copyToStore copies a file to the store, using CoW if available.
func copyToStore(source, objectPath, digest string) error {
	// clones are atomic
	if err := unix.Clonefile(source, objectPath, 0); err == nil {
		return nil
	}

	return fallbackCopyToStore(source, objectPath, digest)
}
