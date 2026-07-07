package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
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

	info, err := os.Lstat(src)
	if err != nil {
		log.Fatal(err)
	}

	if info.IsDir() {
		err = reflinkTree(src, dst, *auto)
	} else {
		err = reflinkFile(src, dst, *auto)
	}
	if err != nil {
		log.Fatal(err)
	}
}

func reflinkTree(src, dst string, auto bool) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)

		switch {
		case d.IsDir():
			info, err := d.Info()
			if err != nil {
				return err
			}
			return os.MkdirAll(target, info.Mode().Perm())
		case d.Type()&fs.ModeSymlink != 0:
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		default:
			return reflinkFile(path, target, auto)
		}
	})
}

func reflinkFile(src, dst string, auto bool) error {
	srcFile, dstFile, err := reflink(src, dst)
	if err != nil && auto {
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

	return err
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
