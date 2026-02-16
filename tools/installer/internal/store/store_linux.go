package store

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// copyToStore copies a file to the store, using CoW if available.
func copyToStore(source, objectPath, digest string) error {
	srcFile, err := os.Open(source)
	if err != nil {
		return fmt.Errorf("failed to open source: %w", err)
	}

	dstFile, err := os.Create(objectPath)
	if err != nil {
		srcFile.Close()
		return fmt.Errorf("failed to create destination: %w", err)
	}

	err = unix.IoctlFileClone(int(dstFile.Fd()), int(srcFile.Fd()))
	srcFile.Close()
	dstFile.Close()

	if err == nil {
		return nil
	}

	os.Remove(objectPath)
	return fallbackCopyToStore(source, objectPath, digest)
}
