// 랩용 HTTP 서버. 속도를 조절한 다운로드 · 버전 · 헬스 엔드포인트와 기동 지연 · 종료 방식을 환경변수로 정한다.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		c := http.Client{Timeout: 1500 * time.Millisecond}
		r, err := c.Get("http://127.0.0.1:8080/health")
		if err != nil || r.StatusCode != 200 {
			os.Exit(1)
		}
		os.Exit(0)
	}

	version := env("VERSION", "v1")
	delay, _ := strconv.Atoi(env("STARTUP_DELAY", "0")) // 초. 이 동안 포트를 열지 않는다
	shutdown := env("SHUTDOWN", "immediate")            // immediate | graceful
	graceSec, _ := strconv.Atoi(env("GRACE_TIMEOUT", "55"))
	host, _ := os.Hostname()

	log.Printf("start version=%s delay=%ds shutdown=%s", version, delay, shutdown)
	time.Sleep(time.Duration(delay) * time.Second)

	var inflight atomic.Int64 // 진행 중 다운로드 수. 배포 스크립트가 옛 색을 멈출 시점을 정하는 데 쓴다

	mux := http.NewServeMux()
	mux.HandleFunc("/inflight", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintf(w, "%d\n", inflight.Load()) })
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "ok") })
	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Version", version)
		w.Header().Set("X-Host", host)
		fmt.Fprintf(w, "%s %s\n", version, host)
	})
	// /download?size=<바이트>&rate=<바이트/초>: size 바이트를 rate 속도로 64KiB 씩 보낸다
	mux.HandleFunc("/download", func(w http.ResponseWriter, r *http.Request) {
		size, _ := strconv.Atoi(r.URL.Query().Get("size"))
		rate, _ := strconv.Atoi(r.URL.Query().Get("rate"))
		if size <= 0 || rate <= 0 {
			http.Error(w, "size, rate required", 400)
			return
		}
		inflight.Add(1)
		defer inflight.Add(-1)
		w.Header().Set("Content-Length", strconv.Itoa(size))
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("X-Version", version)
		w.Header().Set("X-Host", host)
		const chunk = 64 * 1024
		buf := make([]byte, chunk)
		fl, _ := w.(http.Flusher)
		start := time.Now()
		sent := 0
		for sent < size {
			n := chunk
			if size-sent < n {
				n = size - sent
			}
			if _, err := w.Write(buf[:n]); err != nil {
				return
			}
			sent += n
			if fl != nil {
				fl.Flush()
			}
			// 누적 기준으로 속도를 맞춘다: sent 바이트를 보냈어야 할 시각까지 기다린다
			due := start.Add(time.Duration(float64(sent) / float64(rate) * float64(time.Second)))
			if d := time.Until(due); d > 0 {
				time.Sleep(d)
			}
		}
	})

	srv := &http.Server{Addr: ":8080", Handler: mux}
	done := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		s := <-sig
		log.Printf("signal %v shutdown=%s", s, shutdown)
		if shutdown == "graceful" {
			// 리스너를 닫아 새 연결을 받지 않고, 진행 중 응답이 끝날 때까지 기다린다
			ctx, cancel := context.WithTimeout(context.Background(), time.Duration(graceSec)*time.Second)
			defer cancel()
			err := srv.Shutdown(ctx)
			log.Printf("graceful shutdown done err=%v", err)
			close(done)
			return
		}
		os.Exit(0)
	}()
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal(err)
	}
	<-done
}
