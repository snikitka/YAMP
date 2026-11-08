//go:build windows

package gui

import (
	"syscall"
	"unsafe"
)

var (
	crypt32       = syscall.NewLazyDLL("crypt32.dll")
	kernel32      = syscall.NewLazyDLL("kernel32.dll")
	procProtect   = crypt32.NewProc("CryptProtectData")
	procUnprotect = crypt32.NewProc("CryptUnprotectData")
	procLocalFree = kernel32.NewProc("LocalFree")
)

const cryptprotectUIForbidden = 0x1

type dataBlob struct {
	cbData uint32
	pbData *byte
}

func newBlob(b []byte) *dataBlob {
	if len(b) == 0 {
		return &dataBlob{}
	}
	return &dataBlob{cbData: uint32(len(b)), pbData: &b[0]}
}

func (b *dataBlob) bytes() []byte {
	if b.pbData == nil {
		return nil
	}
	return append([]byte(nil), unsafe.Slice(b.pbData, b.cbData)...)
}

var entropy = []byte("yamp/oauth-token/v1")

func protect(plain []byte) ([]byte, error) {
	var out dataBlob
	r, _, err := procProtect.Call(
		uintptr(unsafe.Pointer(newBlob(plain))),
		0,
		uintptr(unsafe.Pointer(newBlob(entropy))),
		0, 0,
		cryptprotectUIForbidden,
		uintptr(unsafe.Pointer(&out)),
	)
	if r == 0 {
		return nil, err
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.pbData)))
	return out.bytes(), nil
}

func unprotect(sealed []byte) ([]byte, error) {
	var out dataBlob
	r, _, err := procUnprotect.Call(
		uintptr(unsafe.Pointer(newBlob(sealed))),
		0,
		uintptr(unsafe.Pointer(newBlob(entropy))),
		0, 0,
		cryptprotectUIForbidden,
		uintptr(unsafe.Pointer(&out)),
	)
	if r == 0 {
		return nil, err
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.pbData)))
	return out.bytes(), nil
}
