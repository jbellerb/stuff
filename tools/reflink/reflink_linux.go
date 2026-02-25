package main

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func reflink(src, dst string) (srcFile, dstFile *os.File, err error) {
	srcFile, err = os.Open(src)
	if err != nil {
		return
	}

	var info os.FileInfo
	info, err = srcFile.Stat()
	if err != nil {
		return
	}

	dstFile, err = os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm())
	if err != nil {
		return
	}

	var srcConn, dstConn syscall.RawConn
	srcConn, err = srcFile.SyscallConn()
	if err != nil {
		return
	}
	dstConn, err = dstFile.SyscallConn()
	if err != nil {
		return
	}

	var errs, errd, err error
	errs = srcConn.Control(func(srcFd uintptr) {
		errd = dstConn.Control(func(dstFd uintptr) {
			err = unix.IoctlFileClone(int(dstFd), int(srcFd))
		})
	})
	if errs != nil {
		err = errs
	} else if errd != nil {
		err = errd
	}

	return
}
