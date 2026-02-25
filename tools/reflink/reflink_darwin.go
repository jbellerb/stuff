package main

import (
	"os"

	"golang.org/x/sys/unix"
)

func reflink(src, dst string) (*os.File, *os.File, error) {
	return nil, nil, unix.Clonefile(src, dst, 0)
}
