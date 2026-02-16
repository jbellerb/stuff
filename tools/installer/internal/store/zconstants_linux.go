package store

import "golang.org/x/sys/unix"

const (
	F_OFD_GETLK  = unix.F_OFD_GETLK
	F_OFD_SETLK  = unix.F_OFD_SETLK
	F_OFD_SETLKW = unix.F_OFD_SETLKW
)
