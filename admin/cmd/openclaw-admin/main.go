package main

import (
	"log"
	"net/http"

	"weixinbot/admin/internal/admin"
)

func main() {
	cfg, err := admin.LoadConfig()
	if err != nil {
		log.Fatal(err)
	}

	server, err := admin.NewServer(cfg)
	if err != nil {
		log.Fatal(err)
	}

	log.Printf("openclaw admin listening on %s", cfg.ListenAddr)
	if err := http.ListenAndServe(cfg.ListenAddr, server.Handler()); err != nil {
		log.Fatal(err)
	}
}
