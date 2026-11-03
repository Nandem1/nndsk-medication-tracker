//go:build e2e

package main

import "testing"

func TestTestAddressesRemainOnLoopback(t *testing.T) {
	for _, raw := range []string{"-1", "40001", "abc", "1.5"} {
		if _, _, err := testAddresses(raw); err == nil {
			t.Fatalf("accepted invalid offset %q", raw)
		}
	}
	for _, c := range []struct{ raw, api, proxy string }{
		{"", "127.0.0.1:18083", "127.0.0.1:18084"},
		{"2000", "127.0.0.1:20083", "127.0.0.1:20084"},
		{"40000", "127.0.0.1:58083", "127.0.0.1:58084"},
	} {
		api, proxy, err := testAddresses(c.raw)
		if err != nil || api != c.api || proxy != c.proxy {
			t.Fatalf("unexpected addresses for %q", c.raw)
		}
	}
}
