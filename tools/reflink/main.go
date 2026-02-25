package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
)

func main() {
	log.SetPrefix("reflink: ")

	auto := flag.Bool("auto", false, "Fall back to copy if reflink fails")
	flag.Parse()

	if flag.NArg() != 2 {
		if flag.NArg() > 2 {
			log.Printf("unexpected argument: %s\n", flag.Arg(2))
		}
		fmt.Fprintln(os.Stderr, "usage: reflink [--auto] <source> <target>")
		os.Exit(1)
	}

	src, dst := flag.Arg(0), flag.Arg(1)

	srcFile, dstFile, err := reflink(src, dst)
	if err != nil && *auto {
		err = fallbackCopy(src, dst, srcFile, dstFile)
	}

	if srcFile != nil {
		srcFile.Close()
	}
	if dstFile != nil {
		dstFile.Close()
		if err != nil && !errors.Is(err, os.ErrExist) {
			os.Remove(dstFile.Name()) // ignores error
		}
	}

	if err != nil {
		log.Fatal(err)
	}
}

func fallbackCopy(src, dst string, srcFile, dstFile *os.File) error {
	var err error
	if srcFile == nil {
		if srcFile, err = os.Open(src); err != nil {
			return err
		}
		defer srcFile.Close()
	}

	var shouldCleanupDst bool
	if dstFile == nil {
		info, err := srcFile.Stat()
		if err != nil {
			return err
		}

		dstFile, err = os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm())
		if err != nil {
			return err
		}
		shouldCleanupDst = true
	}

	_, err = io.Copy(dstFile, srcFile)
	if err != nil && shouldCleanupDst {
		dstFile.Close()
		os.Remove(dstFile.Name()) // ignores error
	}
	return err
}
