package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// winsize is struct winsize from <sys/ttycom.h>.
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

	lock := int(0)
	if err := ioctl(f, syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&lock))); err != nil {
		f.Close()
		return nil, "", fmt.Errorf("ioctl TIOCSPTLCK: %w", err)
	}

	var n uint
	if err := ioctl(f, syscall.TIOCGPTN, uintptr(unsafe.Pointer(&n))); err != nil {
		f.Close()
		return nil, "", fmt.Errorf("ioctl TIOCGPTN: %w", err)
	}

	return f, fmt.Sprintf("/dev/pts/%d", n), nil
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
	if err := ioctl(f, syscall.TCGETS, uintptr(unsafe.Pointer(&t))); err != nil {
		return fmt.Errorf("ioctl TCGETS: %w", err)
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
		-1,               // 11: VDSUSP (not on Linux)
		syscall.VREPRINT, // 12
		syscall.VWERASE,  // 13
		syscall.VLNEXT,   // 14
		-1,               // 15: VFLUSH (not on Linux)
		syscall.VSWTC,    // 16: VSWTCH
		-1,               // 17: VSTATUS (not on Linux)
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
		// RFC uses 255 for "none". On Linux, _POSIX_VDISABLE is 0.
		if val == 255 {
			t.Cc[idx] = 0
		} else {
			t.Cc[idx] = uint8(val)
		}
	}

	setFlag := func(flag *uint32, mask uint32, val uint32) {
		if val != 0 {
			*flag |= mask
		} else {
			*flag &^= mask
		}
	}

	// flagOps maps RFC 4254 flag opcodes to their termios field and bitmask.
	// Zero mask means the opcode is unsupported on this platform.
	type flagOp struct {
		flag *uint32
		mask uint32
	}
	flagOps := [94]flagOp{
		30: {&t.Iflag, syscall.IGNPAR},
		31: {&t.Iflag, syscall.PARMRK},
		32: {&t.Iflag, syscall.INPCK},
		33: {&t.Iflag, syscall.ISTRIP},
		34: {&t.Iflag, syscall.INLCR},
		35: {&t.Iflag, syscall.IGNCR},
		36: {&t.Iflag, syscall.ICRNL},
		37: {&t.Iflag, syscall.IUCLC},
		38: {&t.Iflag, syscall.IXON},
		39: {&t.Iflag, syscall.IXANY},
		40: {&t.Iflag, syscall.IXOFF},
		41: {&t.Iflag, syscall.IMAXBEL},
		42: {&t.Iflag, syscall.IUTF8},
		50: {&t.Lflag, syscall.ISIG},
		51: {&t.Lflag, syscall.ICANON},
		52: {&t.Lflag, syscall.XCASE},
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
		71: {&t.Oflag, syscall.OLCUC},
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

	// opcodes 128-129 set baud rate, Linux's extended termios stores Bxxx speed
	// constants in Ispeed/Ospeed
	if v, ok := modes[128]; ok {
		if b, ok := baudRates[v]; ok {
			t.Ispeed = b
		}
	}
	if v, ok := modes[129]; ok {
		if b, ok := baudRates[v]; ok {
			t.Ospeed = b
		}
	}

	return ioctl(f, syscall.TCSETS, uintptr(unsafe.Pointer(&t)))
}

var baudRates = map[uint32]uint32{
	0:       syscall.B0,
	50:      syscall.B50,
	75:      syscall.B75,
	110:     syscall.B110,
	134:     syscall.B134,
	150:     syscall.B150,
	200:     syscall.B200,
	300:     syscall.B300,
	600:     syscall.B600,
	1200:    syscall.B1200,
	1800:    syscall.B1800,
	2400:    syscall.B2400,
	4800:    syscall.B4800,
	9600:    syscall.B9600,
	19200:   syscall.B19200,
	38400:   syscall.B38400,
	57600:   syscall.B57600,
	115200:  syscall.B115200,
	230400:  syscall.B230400,
	460800:  syscall.B460800,
	500000:  syscall.B500000,
	576000:  syscall.B576000,
	921600:  syscall.B921600,
	1000000: syscall.B1000000,
	1152000: syscall.B1152000,
	1500000: syscall.B1500000,
	2000000: syscall.B2000000,
	2500000: syscall.B2500000,
	3000000: syscall.B3000000,
	3500000: syscall.B3500000,
	4000000: syscall.B4000000,
}
