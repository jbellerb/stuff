//go:build !darwin && !linux

package main

import (
	"errors"
	"os"
)

func reflink(_, _ string) (*os.File, *os.File, error) {
	return nil, nil, errors.New("unsupported platform")
}
