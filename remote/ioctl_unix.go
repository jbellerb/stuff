//go:build unix

package main

import (
	"os"
	"syscall"
)

func ioctl(f *os.File, req uint, arg uintptr) error {
	fConn, err := f.SyscallConn()
	if err != nil {
		return err
	}

	var errf error
	errf = fConn.Control(func(fd uintptr) {
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(req), arg)
		if errno != 0 {
			err = errno
		}
	})
	if errf != nil {
		return errf
	}
	return err
}
