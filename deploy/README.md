# Deploying the gateway

Single VM: install Docker, copy `server/.env` (see `server/README.md`), set the
domain in `Caddyfile`, then `docker compose -f deploy/compose.yml up -d --build`.
Caddy terminates TLS and balances WebSocket and HTTP traffic across both nodes;
no stickiness is needed. For one node, drop `gateway-b` and `nats` and unset
`NATS_URL`.
