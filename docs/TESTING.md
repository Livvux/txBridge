# Tests, evidence and deployment acceptance

## What was executed for this package

The implementation was executed locally under real Lua 5.4 using a Python `ctypes` runner, with mocked FiveM natives/HTTP/KVP/event scheduling and a test JSON adapter. The WordPress plugin was exercised by PHP with WordPress and database doubles, not by installing WordPress. Shared protocol fixtures verify the Lua, PHP and Python request-signing implementations against the same expected HMAC values.

The generated `TEST-RESULTS.txt` in this directory contains the actual recorded test/lint output. Lua and PHP tests check assertions and fail with a nonzero exit code. The Python tests check the CLI protocol/URL validation, surface-audit parser, explicit database identity-column collation and API/catalog consistency. Syntax checks do not replace runtime tests.

## Running tests

On a Debian/Ubuntu development machine with Python 3.10+ and PHP 8.1+, install the Lua shared library (the resource itself does not require this development dependency):

```sh
sudo apt-get install liblua5.4-0 php-cli
python3 tests/run_lua.py
php tests/test_wordpress.php
python3 -m unittest discover -s tests -p 'test_*.py'
node --check wordpress/txbridge-wordpress/assets/status.js
find wordpress -name '*.php' -exec php -l {} \;
```

The Lua runner locates `liblua5.4` via the platform library loader; on a different operating system install an equivalent library or run the test suite in Linux. No pip dependency is needed for these tests. The runtime Lua resource is self-contained. GitHub Actions configuration is supplied, but no remote CI workflow was run as part of creating the ZIP.

## Covered behaviors

SHA-256 and RFC 4231 HMAC vectors; cross-language Unicode-body signing; timestamp/path/body/idempotency tampering; replay rejection across storage reload; peer spoofing; scope/flag gates; body timeouts/limits; native player-ID reuse protection; persisted idempotency; all current documented event subscriptions; privacy defaults and truncation; queue bounds; transient retries/dead letters; native HTTP timeout accounting; explicit upstream route restrictions and 200-with-error handling; WordPress permissions; webhook schema/signature and duplicate conflicts; inbox storage errors; public projection redaction; out-of-order/stale snapshots; receipt cursor semantics; fixed HTTPS client targets; and no secret-bearing shortcode output.

## Not established by these tests

A successful connection to an actual FXServer/txAdmin; behavior of the exact FiveM JSON serializer and KVP persistence under power loss; native resource-control transitions; a real WordPress/MySQL/MariaDB installation and `dbDelta`; conflicts with themes/cache/security plugins; real Nginx/TLS/firewall behavior; compatibility with all txAdmin releases; large binary/log transfers; full database reconciliation; malicious-host isolation; penetration-test approval; sustained-load performance; or production readiness.

None of the user's live infrastructure, GitHub repositories, WordPress settings or txAdmin accounts was modified for this package.

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
