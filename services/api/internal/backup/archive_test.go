package backup

import (
	"bytes"
	"testing"
)

func TestAuthenticatedArchive(t *testing.T) {
	key := bytes.Repeat([]byte{42}, 32)
	plain := []byte("synthetic database dump")
	archive, err := Seal(plain, key)
	if err != nil {
		t.Fatal(err)
	}
	other, err := Seal(plain, key)
	if err != nil || bytes.Equal(archive, other) {
		t.Fatal("nonce was reused", err)
	}
	restored, err := Open(archive, key)
	if err != nil || !bytes.Equal(restored, plain) {
		t.Fatal("round trip", err)
	}
	for i := range archive {
		tampered := append([]byte{}, archive...)
		tampered[i] ^= 1
		if _, err := Open(tampered, key); err == nil {
			t.Fatalf("accepted modified byte %d", i)
		}
	}
	if _, err := Open(archive, bytes.Repeat([]byte{43}, 32)); err == nil {
		t.Fatal("accepted wrong key")
	}
	if _, err := Seal(plain, key[:31]); err == nil {
		t.Fatal("accepted short key")
	}
}
