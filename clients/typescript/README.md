# @txbridge/client

Strictly typed TypeScript client for [txBridge](../../README.md): signed API requests (`TXBRIDGE1`), webhook verification (`TXBRIDGE-WEBHOOK1`), and Zod-validated responses. Node ≥ 22.18, ESM, one runtime dependency (`zod`). Source is shipped as TypeScript (`allowImportingTsExtensions`); TypeScript monorepos import it directly.

**Status:** protocol verified against the Lua bridge with shared vectors (`tests/signing-vectors.json`) and against a local HTTP double that applies the bridge's verification rules. Not yet exercised against a live FXServer – see `docs/TESTING.md`.

## API client

```ts
import { TxBridgeClient, TxBridgeError, newIdempotencyKey } from "@txbridge/client";

const bridge = new TxBridgeClient({
  baseUrl: "https://fivem.example.com/txbridge", // https only; no credentials/query/fragment
  serverId: "main",                              // txbridge_server_id
  keyId: "modly",                                 // Config.Clients slot
  secret: process.env.TXBRIDGE_SECRET!,           // 32–256 chars
  // fetch: guardedFetch,  timeoutMs: 10_000,  maxResponseBytes: 1_048_576
});

await bridge.health();      // { healthy, serverId }
await bridge.status();      // BridgeStatus
await bridge.players();     // BridgePlayer[]  (names "[redacted]" unless the bridge opts in)
await bridge.resources();   // BridgeResource[]
await bridge.events({ after: 41, limit: 100 }); // { items, cursor, latest, oldestAvailable, gap }

// Write actions need the matching scope AND Config.Actions flag on the bridge.
const key = newIdempotencyKey(); // persist before sending; reuse it for retries
await bridge.resourceAction("my_resource", "restart", key);
```

Guarantees:

- Fresh nonce per request (the bridge rejects reused nonces), timestamp from the injectable clock.
- The signed path is resource-relative and includes the query string, exactly as the bridge sees `req.path`.
- `redirect: "error"`, request timeout, response size limit, `{ok,data|error}` envelope and payload validation.
- POST never auto-retries. After a `transport`/`timeout` error the outcome is unknown: retry only with the same idempotency key (the bridge returns the stored response or `409 outcome_unknown`).

Errors are `TxBridgeError` with `kind` `transport | timeout | too_large | invalid_response | bridge`, plus `status` and the bridge's `code` (e.g. `forbidden`, `replayed_request`, `player_session_changed`).

## Webhook receiver

```ts
import { verifyWebhook } from "@txbridge/client";

const raw = new Uint8Array(await request.arrayBuffer());
const result = verifyWebhook({ secret, serverId: "main", headers: request.headers, body: raw }); // ±300 s window
if (!result.ok) {
  // too_large → 413; anything else → 401 (or 400 for invalid_envelope). The bridge dead-letters these.
}
// Deduplicate by (serverId, result.event.id); answer 2xx for new and duplicate events.
```

Nothing from the body is parsed before the HMAC over the raw bytes matches. A valid signature with a contradictory envelope (`id`, `serverId`, non-integer `sequence`, unknown `version`/`type` namespace) is `invalid_envelope`.

## Signing primitives

`canonicalRequest`, `canonicalWebhook`, `signRequest`, `signWebhook`, `verifyRequest` (server side, for test doubles and compatible bridges), `sha256Hex`, `hmacHex`, `safeEqualHex`, `isStrongSecret`, `newNonce`, `newIdempotencyKey`.

## Development

```sh
npm ci
npm run typecheck
npm test   # node --test, includes shared vectors and an HTTP double
```
