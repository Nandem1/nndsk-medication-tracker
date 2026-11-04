//go:build e2e

package main

import (
	"log"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync/atomic"
	"time"
)

// faultMode describe qué ocurre con las peticiones de negocio que atraviesan el proxy.
// Corta conexiones TCP reales: el cliente observa los mismos fallos que con una red caída.
type faultMode int32

const (
	online faultMode = iota
	// offline cierra la conexión sin llegar a la API.
	offline
	// loseResponses deja que la API aplique la petición y descarta la respuesta de cada POST.
	loseResponses
	// stalled retiene las peticiones hasta salir de este modo, como una red muy lenta.
	stalled
)

func serveFaultProxy(address, target string) {
	upstream, err := url.Parse(target)
	if err != nil {
		log.Fatal("invalid proxy target")
	}
	forward := httputil.NewSingleHostReverseProxy(upstream)
	var mode atomic.Int32
	mux := http.NewServeMux()
	mux.HandleFunc("POST /__fault/{mode}", func(w http.ResponseWriter, r *http.Request) {
		switch r.PathValue("mode") {
		case "online":
			mode.Store(int32(online))
		case "offline":
			mode.Store(int32(offline))
		case "lose-responses":
			mode.Store(int32(loseResponses))
		case "stall":
			mode.Store(int32(stalled))
		default:
			http.Error(w, "unknown mode", http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch faultMode(mode.Load()) {
		case offline:
			drop(w)
		case loseResponses:
			if r.Method == http.MethodPost && (strings.HasPrefix(r.URL.Path, "/v1/doses/") || strings.HasPrefix(r.URL.Path, "/v1/inventory/")) {
				forward.ServeHTTP(httptest.NewRecorder(), r)
				drop(w)
				return
			}
			forward.ServeHTTP(w, r)
		case stalled:
			for faultMode(mode.Load()) == stalled {
				select {
				case <-r.Context().Done():
					return
				case <-time.After(50 * time.Millisecond):
				}
			}
			forward.ServeHTTP(w, r)
		default:
			forward.ServeHTTP(w, r)
		}
	})
	server := &http.Server{Addr: address, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(server.ListenAndServe())
}

func drop(w http.ResponseWriter) {
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		panic(http.ErrAbortHandler)
	}
	connection, _, err := hijacker.Hijack()
	if err != nil {
		panic(http.ErrAbortHandler)
	}
	_ = connection.Close()
}
