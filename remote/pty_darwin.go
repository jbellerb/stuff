package main

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// winsize is struct winsize from <asm/termios.h>.
type winsize struct {
	Row    uint16
	Col    uint16
	Xpixel uint16
	Ypixel uint16
}

func openPty() (*os.File, string, error) {
	f, err := os.OpenFile("/dev/ptmx", syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, "", &os.PathError{Op: "open", Path: "/dev/ptmx", Err: err}
	}

	if err := ioctl(f, syscall.TIOCPTYGRANT, 0); err != nil {
		f.Close()
		return nil, "", fmt.Errorf("ioctl TIOCPTYGRANT: %w", err)
	}

	if err := ioctl(f, syscall.TIOCPTYUNLK, 0); err != nil {
		f.Close()
		return nil, "", fmt.Errorf("ioctl TIOCPTYUNLK: %w", err)
	}

	// IOCPARM_LEN(TIOCPTYGNAME)
	var name [128]byte
	if err := ioctl(f, syscall.TIOCPTYGNAME, uintptr(unsafe.Pointer(&name[0]))); err != nil {
		f.Close()
		return nil, "", fmt.Errorf("ioctl TIOCPTYGNAME: %w", err)
	}

	for i, c := range name {
		if c == 0 {
			return f, string(name[:i]), nil
		}
	}

	f.Close()
	return nil, "", errors.New("TIOCPTYGNAME string missing null terminator")
}

func setWinsize(f *os.File, rows, cols, width, height uint16) error {
	ws := winsize{Row: rows, Col: cols, Xpixel: width, Ypixel: height}
	return ioctl(f, syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))
}

func applyModes(f *os.File, modes map[byte]uint32) error {
	if len(modes) == 0 {
		return nil
	}

	var t syscall.Termios
	if err := ioctl(f, syscall.TIOCGETA, uintptr(unsafe.Pointer(&t))); err != nil {
		return fmt.Errorf("ioctl TIOCGETA: %w", err)
	}

	// ccOpcodes maps RFC 4254 control character opcodes (1–18) to Cc array
	// indices. -1 means the character is unsupported on this platform.
	ccOpcodes := [19]int{
		-1,               // 0: TTY_OP_END (unused)
		syscall.VINTR,    // 1
		syscall.VQUIT,    // 2
		syscall.VERASE,   // 3
		syscall.VKILL,    // 4
		syscall.VEOF,     // 5
		syscall.VEOL,     // 6
		syscall.VEOL2,    // 7
		syscall.VSTART,   // 8
		syscall.VSTOP,    // 9
		syscall.VSUSP,    // 10
		syscall.VDSUSP,   // 11
		syscall.VREPRINT, // 12
		syscall.VWERASE,  // 13
		syscall.VLNEXT,   // 14
		-1,               // 15: VFLUSH (not on Darwin)
		-1,               // 16: VSWTCH (not on Darwin)
		syscall.VSTATUS,  // 17
		syscall.VDISCARD, // 18
	}
	for opcode := byte(1); opcode <= 18; opcode++ {
		val, ok := modes[opcode]
		if !ok {
			continue
		}
		idx := ccOpcodes[opcode]
		if idx < 0 || idx >= len(t.Cc) {
			continue
		}
		t.Cc[idx] = uint8(val) // RFC uses 255 for "none" = _POSIX_VDISABLE on Darwin
	}

	setFlag := func(flag *uint64, mask uint64, val uint32) {
		if val != 0 {
			*flag |= mask
		} else {
			*flag &^= mask
		}
	}

	// flagOps maps RFC 4254 flag opcodes to their termios field and bitmask.
	// Zero mask means the opcode is unsupported on this platform.
	type flagOp struct {
		flag *uint64
		mask uint64
	}
	flagOps := [94]flagOp{
		30: {&t.Iflag, syscall.IGNPAR},
		31: {&t.Iflag, syscall.PARMRK},
		32: {&t.Iflag, syscall.INPCK},
		33: {&t.Iflag, syscall.ISTRIP},
		34: {&t.Iflag, syscall.INLCR},
		35: {&t.Iflag, syscall.IGNCR},
		36: {&t.Iflag, syscall.ICRNL},
		// 37: IUCLC is not available on Darwin
		38: {&t.Iflag, syscall.IXON},
		39: {&t.Iflag, syscall.IXANY},
		40: {&t.Iflag, syscall.IXOFF},
		41: {&t.Iflag, syscall.IMAXBEL},
		42: {&t.Iflag, syscall.IUTF8},
		50: {&t.Lflag, syscall.ISIG},
		51: {&t.Lflag, syscall.ICANON},
		// 52: XCASE is not available on Darwin
		53: {&t.Lflag, syscall.ECHO},
		54: {&t.Lflag, syscall.ECHOE},
		55: {&t.Lflag, syscall.ECHOK},
		56: {&t.Lflag, syscall.ECHONL},
		57: {&t.Lflag, syscall.NOFLSH},
		58: {&t.Lflag, syscall.TOSTOP},
		59: {&t.Lflag, syscall.IEXTEN},
		60: {&t.Lflag, syscall.ECHOCTL},
		61: {&t.Lflag, syscall.ECHOKE},
		62: {&t.Lflag, syscall.PENDIN},
		70: {&t.Oflag, syscall.OPOST},
		// 71: OLCUC is not available on Darwin
		72: {&t.Oflag, syscall.ONLCR},
		73: {&t.Oflag, syscall.OCRNL},
		74: {&t.Oflag, syscall.ONOCR},
		75: {&t.Oflag, syscall.ONLRET},
		92: {&t.Cflag, syscall.PARENB},
		93: {&t.Cflag, syscall.PARODD},
	}
	for i, op := range flagOps {
		if op.mask == 0 {
			continue
		}
		if v, ok := modes[byte(i)]; ok {
			setFlag(op.flag, op.mask, v)
		}
	}

	// opcodes 90–91 set character width, a multi-bit field requiring mask and
	// set
	if v, ok := modes[90]; ok && v != 0 {
		t.Cflag = (t.Cflag &^ syscall.CSIZE) | syscall.CS7
	}
	if v, ok := modes[91]; ok && v != 0 {
		t.Cflag = (t.Cflag &^ syscall.CSIZE) | syscall.CS8
	}

	// opcodes 128-129 set baud rate, Darwin's extended termios stores raw baud
	// rate values in Ispeed/Ospeed
	if v, ok := modes[128]; ok {
		t.Ispeed = uint64(v)
	}
	if v, ok := modes[129]; ok {
		t.Ospeed = uint64(v)
	}

	return ioctl(f, syscall.TIOCSETA, uintptr(unsafe.Pointer(&t)))
}
