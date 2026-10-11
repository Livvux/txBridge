# Tests, evidence and deployment acceptance

## What was executed for this package

The implementation was executed locally under real Lua 5.4 using a Python `ctypes` runner, with mocked FiveM natives/HTTP/KVP/event scheduling and a test JSON adapter. The WordPress plugin was exercised by PHP with WordPress and database doubles, not by installing WordPress. Shared protocol fixtures verify the Lua, PHP, Python and TypeScript signing implementations against the same expected HMAC values.

`tests/signing-vectors.json` is generated **from the Lua bridge** by `tools/signing_vectors.lua` (GET with and without query, Unicode POST, secrets longer than the HMAC block, `[]`-encoded empty data). Lua, PHP (`TXBridge_Signing`), Python (stdlib `hmac` and the CLI) and the TypeScript client (`clients/typescript`) all check every vector; consumers that vendor the TypeScript client (Modly) check the same file.

The generated `TEST-RESULTS.txt` in this directory contains the actual recorded test/lint output. Lua and PHP tests check assertions and fail with a nonzero exit code. The Python tests check the CLI protocol/URL validation, surface-audit parser, explicit database identity-column collation and API/catalog consistency. Syntax checks do not replace runtime tests.

## Running tests

On a Debian/Ubuntu development machine with Python 3.10+ and PHP 8.1+, install the Lua shared library (the resource itself does not require this development dependency):

```sh
sudo apt-get install liblua5.4-0 lua5.4 php-cli
python3 tests/run_lua.py
php tests/test_wordpress.php
python3 -m unittest discover -s tests -p 'test_*.py'
lua5.4 tools/signing_vectors.lua --check
node --check wordpress/txbridge-wordpress/assets/status.js
find wordpress -name '*.php' -exec php -l {} \;
(cd clients/typescript && npm ci && npm run typecheck && npm test)
```

macOS: `brew install lua@5.4`, then run the Lua runner with `DYLD_LIBRARY_PATH=/opt/homebrew/opt/lua@5.4/lib` and the generator with `/opt/homebrew/opt/lua@5.4/bin/lua`. The TypeScript tests use the Node test runner with built-in type stripping (Node ≥ 22.18); they start a local HTTP double that verifies requests with the bridge's own rules.

The Lua runner locates `liblua5.4` via the platform library loader; on a different operating system install an equivalent library or run the test suite in Linux. No pip dependency is needed for these tests. The runtime Lua resource is self-contained. `.github/workflows/tests.yml` runs all of the above on every push and pull request.

## Covered behaviors

SHA-256 and RFC 4231 HMAC vectors; cross-language Unicode-body signing; timestamp/path/body/idempotency tampering; replay rejection across storage reload; peer spoofing; scope/flag gates; body timeouts/limits; native player-ID reuse protection; persisted idempotency; all current documented event subscriptions; privacy defaults and truncation; queue bounds; transient retries/dead letters; native HTTP timeout accounting; explicit upstream route restrictions and 200-with-error handling; WordPress permissions; webhook schema/signature and duplicate conflicts; inbox storage errors; public projection redaction; out-of-order/stale snapshots; receipt cursor semantics; fixed HTTPS client targets; and no secret-bearing shortcode output. Since 0.1.1 also: byte-limited text truncation that never splits a UTF-8 code point; integer counters and event sequences after a KVP round trip that returns floats; the `modly` consumer slot (own scopes, own signed webhook, both consumers queued per event); and the TypeScript client (signed reads incl. query strings, fresh nonce per request, caller-owned idempotency keys, envelope/payload validation, response size limit, redirect refusal, timeouts, webhook verification and envelope cross-checks).

## Not established by these tests

A successful connection to an actual FXServer/txAdmin; behavior of the exact FiveM JSON serializer and KVP persistence under power loss; native resource-control transitions; a real WordPress/MySQL/MariaDB installation and `dbDelta`; conflicts with themes/cache/security plugins; real Nginx/TLS/firewall behavior; compatibility with all txAdmin releases; large binary/log transfers; full database reconciliation; malicious-host isolation; penetration-test approval; sustained-load performance; or production readiness.

None of the user's live infrastructure, GitHub repositories, WordPress settings or txAdmin accounts was modified for this package.

## FXServer acceptance tests (first live run)

These nine checks target the exact places where the code relies on behavior that the mocks cannot prove. Run them on a disposable FXServer with the intended txAdmin build **before** the generic checklist below. Use the CLI (`tools/txbridge_cli.py`) with the `modly` or `wordpress` slot; for webhooks point a slot at a receiver you can inspect (a Modly staging server or `https://webhook.site`-style inbox you control).

Setup: record `GetConvar('version')` (FXServer build) and the txAdmin version; set convars with `set` before `ensure txbridge`; create an empty resource `txb_dummy` and add it to `Config.Actions.allowedResources` only for check 6.

| # | Risk | Code relying on it | Steps | Pass criteria |
|---|---|---|---|---|
| 1 | Whole numbers come back as floats from the FiveM JSON serializer | `core.lua` (`B.int` normalization on load), `events.lua` (`id = serverId..'-'..sequence`) | `restart txbridge` twice, then `GET /v1/events?after=0&limit=5`, `GET /v1/players`, and capture one webhook body | `sequence`, `emittedAt`, event `id` and `sessionId` contain no `.0`; WordPress/Modly answer 2xx |
| 2 | Signed target differs from the real `req.path` | `api.lua` signs `req.path` incl. query | `GET /v1/status`, then `GET '/v1/events?after=0&limit=5'`, once via loopback and once through nginx | Both 200 on both routes. A 401 only for the query request means `req.path` lacks the query string |
| 3 | Unknown `req.address` format | `security.lua` `B.peer` | One request through nginx, one directly to `:30120/txbridge/v1/health` from outside, one with a spoofed `X-Forwarded-For: 127.0.0.1` | Only the nginx request passes; the other two return 403 |
| 4 | txAdmin events silently dropped by the origin check | `events.lua` `B.capture` (`source`, `GetInvokingResource()`) | In the panel: announcement, schedule + skip a restart, warn and kick a test player | `/v1/events` lists `txadmin.*` with `origin=txadmin_event` and the documented fields. If nothing arrives, the invoker is not `monitor` – note the actual value (temporary local debug print), do not widen `trustedResources` blindly |
| 5 | POST body handler / empty-object encoding | `api.lua` `setDataHandler`, `B.object`; `{}` vs `[]` | Enable `announce` for the test slot and send one; save the txAdmin settings once (`configChanged`) | No 408/400 on the POST; the `configChanged` webhook has `data` as `[]` or `{}` and the receiver accepts it |
| 6 | Resource transitions differ from the mock | `api.lua` resource actions (stop+start in one tick) | `stop`, `start`, `restart` on `txb_dummy`; try `monitor` and `txbridge` | `after` in each response matches the console state; protected names return 403 |
| 7 | KVP write load causes hitches | `B.save('journal')` on every publish, request and snapshot | Disable the webhook target, run 20–30 min with joins/resource events, watch hitch warnings; then `txbridge_status`, re-enable the target, retry dead letters | No new hitch warnings attributable to txBridge; outbox bounded; retry delivers once per event |
| 8 | Restart while actions/deliveries are in flight | sessions, idempotency store, outbox | `restart txbridge` right after an action; repeat the action with the same idempotency key; check `boot` | Old `sessionId` → 409; same key → stored response; outbox drains; `bridge.started.boot` incremented; host clocks within ±90 s |
| 9 | UTF-8 in names and texts | `B.truncate`, byte-based limits | Join with an emoji/umlaut name, enable `includePlayerNames`, send a long Unicode announcement | Webhook bodies are valid UTF-8 JSON; names arrive unchanged |

Record each result (pass/fail, observed values, versions) in `docs/TEST-RESULTS.txt` under a dated "Live FXServer" heading. Until all nine pass, the bridge remains an integration-test candidate.

## Required staging acceptance

1. Start the resource on a disposable server managed by the intended txAdmin build. Confirm actual `/txbridge/v1/...` routing, Lua load/JSON array behavior, monitor events, valid secret loading and KVP writes.
2. Verify a valid signed read works through TLS, while unsigned, replayed, expired, wrong-server, altered-body and missing-scope requests fail. Attempt direct raw-port access and spoofed forwarded-IP headers; both must remain forbidden from untrusted peers.
3. Activate the plugin on staging with the actual database engine. Confirm table creation, unique-key behavior, webhook first/duplicate/conflict responses and unauthorized admin-route rejection. Check REST cookie nonces/capabilities in the real WordPress stack.
4. Observe genuine txAdmin scheduled-restart/announcement and appropriate disposable moderation/allowlist events. Confirm intended redaction and exact fields. Do not manufacture event notifications and call that proof of txAdmin action execution.
5. Interrupt the webhook receiver, watch bounded retries/dead letters, restore it, retry a retained delivery and verify a single durable inbox row. Test an out-of-order snapshot and public stale indication without publishing private payloads.
6. Restart the resource and then FXServer; confirm retained delivery/sequence/idempotency behavior and new player session IDs. Test a replacement player reusing a net ID; an old session token must not act on them. Exercise backup/identity-reset procedures separately.
7. Enable only one harmless native action on staging, verify scope/feature controls and retry semantics, then return to the intended minimal production policy. For resource actions use a disposable allowlisted test resource, not `monitor` or the bridge.
8. If internal txAdmin access is necessary, test the exact intended route/action on the pinned build using a limited authorized session. Test session expiry and 200-with-error/partial-success handling. Check response privacy, and test with the adapter disabled again after an upgrade.
9. Verify clock synchronization, certificate renewal, host firewall, actual proxy source IP, retention cleanup, disk/DB growth, queue alerts and load at the intended player/event volume. Confirm an independent recovery path exists when FXServer is stopped.

Record your environment, exact txAdmin/FXServer versions, outcomes and any deviations before using this on a production server.
