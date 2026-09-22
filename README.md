# txBridge · FiveM ↔ applications

<img width="1672" height="941" alt="txBridge" src="https://github.com/user-attachments/assets/58137119-cbf4-4e1a-8962-a7d3ef838b1c" />


**Version 0.1.0 — implementation and integration-test candidate.** Server-only Lua resource, WordPress plugin, signed HTTP client, OpenAPI specification, and deployment documentation. No paid dependency, framework dependency, RCON password, or monitor-token extraction is required for the normal integration.

```text
                     authenticated, scoped requests
WordPress / your app ───────── HTTPS reverse proxy ────────┐
                                                         ▼
                                                  FiveM: txbridge
WordPress webhook inbox ◀──── signed HTTPS events ────────┤
                                                         ├─ FiveM server natives
                                                         ├─ 17 documented txAdmin events
                                                         ├─ optional host-status endpoint
                                                         └─ optional internal web-session adapter
```

## What is included

| Capability | Implementation |
|---|---|
| Current documented txAdmin events | All 17 captured; three deprecated names optionally captured |
| Data API | Status, players, resources, event cursor, observed txAdmin state, private audit, queue monitoring |
| Controlled native actions | Announce, direct chat, kick, resource start/stop/restart; disabled until explicitly granted |
| Delivery | Persistent bounded outbox, signed webhooks, retries, dead letters, retry endpoint |
| WordPress | Signed durable inbox, protected application client, administrator endpoints, opt-in public shortcode |
| txAdmin HTTP inventory | All 58 registrations in the pinned central router, including two development-only registrations |
| Experimental adapter | 42 internal route templates, disabled by default; explicit exact-parameter grants, per-route scopes and authorized session |
| Documentation | Installation, every bridge operation and export, event fields, all inventoried upstream routes, security, testing, OpenAPI |

**This is not a supported, universal txAdmin management API.** The documented server events are observations, not commands. The internal panel routes are version-dependent. This package does not obtain private intercom credentials, spoof administrators, expose development routes, or automate txAdmin account/login flows. Events missed during downtime cannot reconstruct the complete txAdmin database. The Lua resource cannot operate while FXServer is stopped, including starting that stopped process.

Upstream reviewed: `citizenfx/txAdmin`, commit **8a9a41410000fd92a527fe11bae2b8eeeb8b10e0**, on **2026-09-22**. The complete inventory is a snapshot of that router, not a claim that every private function, dynamic action, WebSocket message, binary download, or future route is implemented and tested.

## Start here

1. Copy `resource/txbridge` into your FXServer `resources` directory. Merge `examples/server.cfg` before `ensure txbridge`, replacing all placeholders with independent secrets.
2. Install the `wordpress/txbridge-wordpress` plugin, configure `examples/wp-config.php`, and use your WordPress HTTPS webhook URL.
3. For requests from WordPress back to FiveM, configure the restricted HTTPS proxy in `deploy/nginx.conf.example`. Outbound-only event delivery does not need an inbound public API.

Read [Installation](docs/INSTALLATION.md) before exposing any endpoint. For a public player-count widget, explicitly set `public_status` to `true`, then insert:

```text
[txbridge_status server="main"]
```

## Documentation

[Installation](docs/INSTALLATION.md) · [HTTP API](docs/API.md) · [Authentication](docs/AUTHENTICATION.md) · [Events](docs/EVENTS.md) · [txAdmin route coverage](docs/TXADMIN.md) · [WordPress](docs/WORDPRESS.md) · [Functions and modules](docs/FUNCTIONS.md) · [Security and operations](docs/SECURITY.md) · [Tests and acceptance](docs/TESTING.md) · [Sources](docs/SOURCES.md)

A standalone reading copy is at `docs/handbook.html`. Machine-readable contracts are `docs/openapi.yaml`, `docs/openapi.json`, `docs/txadmin-routes.json`, and `docs/txadmin-events.json`.

## Local tests

```sh
python3 tests/run_lua.py
php tests/test_wordpress.php
python3 -m unittest discover -s tests -p 'test_*.py'
node --check wordpress/txbridge-wordpress/assets/status.js
```

The Lua runner uses the actual Lua 5.4 shared library with mocked FiveM natives. PHP tests use WordPress/database doubles. **Neither is a live FXServer, txAdmin, WordPress, MySQL, reverse-proxy, or load test.** Complete the staging acceptance checklist before production use.

## License

MIT. Independent integration; not an official Cfx.re, txAdmin, or WordPress product. No upstream txAdmin source distribution is included.
