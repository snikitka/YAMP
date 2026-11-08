//go:build !windows

package gui

func protect(plain []byte) ([]byte, error) { return plain, nil }

func unprotect(sealed []byte) ([]byte, error) { return sealed, nil }
