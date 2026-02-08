package store

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// copyToStore copies a file to the store, using CoW if available.
func copyToStore(source, objectPath, digest string) error {
	// clones are atomic
	if err := unix.Clonefile(source, objectPath, 0); err == nil {
		return nil
	}

	// fall back to regular copy with temporary path and atomic rename
	tmpPath := objectPath + ".tmp"
	if err := copyToStore(source, tmpPath, digest); err != nil {
		return err
	}
	if err := os.Chmod(tmpPath, 0444); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("failed to set permissions: %w", err)
	}
	if err := os.Rename(tmpPath, objectPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("failed to move file to store: %w", err)
	}

	return nil
}
