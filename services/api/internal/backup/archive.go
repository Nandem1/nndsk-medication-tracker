package backup

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
)

var magic = []byte("MEDBACKUP1")

func Seal(plain, key []byte) ([]byte, error) {
	gcm, err := aead(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return nil, errors.New("cannot generate backup nonce")
	}
	prefix := append(append([]byte{}, magic...), nonce...)
	return gcm.Seal(prefix, nonce, plain, magic), nil
}

func Open(data, key []byte) ([]byte, error) {
	gcm, err := aead(key)
	if err != nil {
		return nil, err
	}
	start := len(magic)
	if len(data) < start+gcm.NonceSize()+gcm.Overhead() || string(data[:start]) != string(magic) {
		return nil, errors.New("invalid backup archive")
	}
	plain, err := gcm.Open(nil, data[start:start+gcm.NonceSize()], data[start+gcm.NonceSize():], magic)
	if err != nil {
		return nil, errors.New("backup authentication failed")
	}
	return plain, nil
}

func aead(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, errors.New("backup key must contain exactly 32 raw bytes")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
