# Consumers

txBridge is consumer-agnostic. The Lua resource knows only **named consumer slots**; WordPress is one consumer among others. Each slot has its own secret, its own scopes and its own webhook target, so one consumer can be revoked or rotated without touching the others.

| Slot | Convars | Default scopes | Shipped consumer |
|---|---|---|---|
| `wordpress` | `txbridge_wordpress_secret`, `txbridge_webhook_url`, `txbridge_webhook_secret` | status, players, resources, events (read) | `wordpress/txbridge-wordpress` (unchanged; legacy convar names kept) |
| `modly` | `txbridge_modly_secret`, `txbridge_modly_webhook_url`, `txbridge_modly_webhook_secret` | status, players, resources, events (read) | Modly FiveM Control (`modly.cc`, module `fivem-control`) |

A slot whose secret/URL convars are empty is inert: its API key is rejected with 401 and no webhooks are queued for it. Both slots can run at the same time; every event is queued once per configured webhook slot.

## Wire protocol (summary)

Full details: [Authentication](AUTHENTICATION.md), [HTTP API](API.md), [Events](EVENTS.md).

- **API requests (`TXBRIDGE1`)** – consumer → bridge, through a restricted HTTPS reverse proxy. Headers `X-TxBridge-Key` (slot), `X-TxBridge-Timestamp` (10-digit Unix seconds, ±90 s), `X-TxBridge-Nonce` (24–128 `[A-Za-z0-9_-]`, single use), `X-TxBridge-Signature`, and `Idempotency-Key` (required for POST). Signature = HMAC-SHA256 (lowercase hex) over
  `TXBRIDGE1\n<serverId>\n<key>\n<METHOD>\n<resource-relative path incl. query>\n<timestamp>\n<nonce>\n<idempotency key or empty>\n<sha256hex(body)>`.
- **Webhooks (`TXBRIDGE-WEBHOOK1`)** – bridge → consumer, outbound only; the FiveM host needs no inbound port for them. Headers `X-TxBridge-Server`, `X-TxBridge-Event`, `X-TxBridge-Timestamp`, `X-TxBridge-Signature` over
  `TXBRIDGE-WEBHOOK1\n<serverId>\n<eventId>\n<timestamp>\n<sha256hex(raw body)>`.
  Delivery is **at-least-once**: retries reuse the identical body with a fresh timestamp. Receivers must verify the HMAC over the raw bytes, enforce a timestamp window, and deduplicate by `(serverId, event.id)`. Answer 2xx on success *and* on duplicates, 408/429/5xx for transient problems (the bridge retries), any other 4xx only for permanent rejection (the bridge dead-letters it).
- **Envelope** – `{version:1, id:"<serverId>-<sequence>", sequence, serverId, type, origin, emittedAt, data}`. `sequence` is monotonic per bridge journal; a lower sequence after a KVP reset/reinstall starts a new journal. Empty Lua objects may be encoded as `[]`. `bridge.status` snapshots arrive every `Config.Events.snapshotIntervalSeconds` (default 30 s).
- **Gaps** – detect missing sequences and fetch them with `GET /v1/events?after=<last contiguous>` while they are still retained (`Config.Events.retention`, default 200 events). `gap: true` in that response means they are gone.

## TypeScript client

`clients/typescript` (`@txbridge/client`) implements both schemes, a signed API client with validated responses, and webhook verification. It has one runtime dependency (`zod`) and no build step for TypeScript consumers.

```ts
import { TxBridgeClient, verifyWebhook } from "@txbridge/client";

// Pull (optional): needs the bridge behind the HTTPS proxy from deploy/nginx.conf.example.
const bridge = new TxBridgeClient({ baseUrl: "https://fivem.example.com/txbridge", serverId: "main", keyId: "modly", secret });
const status = await bridge.status();
const { items, gap } = await bridge.events({ after: lastContiguousSequence, limit: 100 });

// Push: in your webhook route, with the raw body.
const result = verifyWebhook({ secret: webhookSecret, serverId: "main", headers: request.headers, body: rawBody });
if (!result.ok) return new Response(null, { status: result.reason === "too_large" ? 413 : 401 });
// store result.event idempotently by (serverId, event.id), then 202 – or 200 for a duplicate
```

See [`clients/typescript/README.md`](../clients/typescript/README.md) for the full API, error kinds and idempotency rules.

## Pairing with Modly

1. In the Modly dashboard (module *FiveM Control*), add a server with its `txbridge_server_id`. Modly generates both secrets and shows a ready `server.cfg` block **once**:
   ```cfg
   set txbridge_server_id "main"
   set txbridge_modly_webhook_url "https://modly.cc/api/fivem/<connection-id>/webhook"
   set txbridge_modly_webhook_secret "<64 hex>"
   set txbridge_modly_secret "<64 hex>"
   ```
2. Paste it before `ensure txbridge` and restart the resource. The first valid signed webhook completes the pairing; only someone who controls `server.cfg` can produce it.
3. Optional: to see player and resource lists in Modly, expose the bridge through the restricted proxy and enter its base URL in Modly. Allow only Modly's egress addresses at the proxy.

Modly P0 is read-only: the `modly` slot ships without any `actions:*` scope.

## Adding another consumer

Add an entry to `Config.Clients` and/or `Config.Webhooks` in `config.lua` with its own convar names and the narrowest scopes, generate independent secrets (`openssl rand -hex 32`), and verify your implementation against `tests/signing-vectors.json`. Never share a secret between slots.
