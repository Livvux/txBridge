# Authentication and request protocol

## Trust boundaries

All Lua endpoints, including health/capability reads, require a client key ID and HMAC signature. Each client has an independent secret and scopes. HMAC authenticates the request body and target; it does not encrypt them. Use HTTPS from the application to the proxy and a trusted private/loopback hop to FXServer. The Lua API additionally restricts actual socket peers. No browser CORS access is provided to this private API.

A WordPress public status endpoint is a separate, explicitly enabled projection. WordPress administrator endpoints use WordPress authentication and `manage_options`; do not replace that with an always-true permission callback. Standard WordPress cookie-authenticated REST calls also need WordPress's REST nonce.

## Request headers

| Header | Rule |
|---|---|
| `X-TxBridge-Key` | Configured client ID, 1–64 ASCII letters, digits, `_`, `-` |
| `X-TxBridge-Timestamp` | Decimal Unix time in seconds; server accepts ±90 seconds by default |
| `X-TxBridge-Nonce` | Fresh 24–128 character ASCII letter/digit/underscore/hyphen value |
| `X-TxBridge-Signature` | Lowercase hex HMAC-SHA256 of the canonical string |
| `Idempotency-Key` | Required for every POST; 16–128 characters using the same safe alphabet |
| `Content-Type` | `application/json` for every POST |

Requests do not use cookies or query-string secrets. GET has no body. POST must contain a JSON object, even when empty (`{}`). UTF-8 body size is capped at 32 KiB. Sign the exact bytes actually sent; do not sign an object and serialize it differently afterwards.

## Canonical request

Join these nine lines with a single LF (`\n`) and **no trailing newline**:

```text
TXBRIDGE1
<serverId>
<keyId>
<UPPERCASE_METHOD>
<resource-relative path with exact raw query string>
<timestamp>
<nonce>
<idempotency key, or an empty line for GET>
<lowercase hex SHA256 of exact body bytes>
```

Compute `hex(HMAC-SHA256(secret_utf8, canonical_utf8))`.

The signed path is `/v1/status`, **not** `/txbridge/v1/status`. For `/v1/events?after=0&limit=50`, preserve that complete target byte-for-byte, including query ordering and percent-encoding. The external URL combines your fixed base (`https://bridge.example.com/txbridge`) with that signed relative target.

The timestamp, nonce and idempotency key are part of the signature. The nonce is checked against a bounded persistent replay cache. Expiry accounts for the accepted timestamp window, including slightly future-dated requests. A consumed nonce cannot be used again even when the action was rejected for missing scope.

`tests/protocol-vectors.json` contains fixed, non-secret test credentials and expected signatures. Its timestamp is intentionally historical and not usable as a live request. Python, Lua and PHP tests check the same fixture, including a Unicode message.

## POST retries and idempotency

The bridge persists a pending record before dispatching a POST. A completed duplicate with the same client, idempotency key, method, path and exact body returns the recorded response instead of executing again. The retry must have a **new nonce/signature**. A different payload with the same key is rejected.

Defaults: at most 512 retained records, 24-hour TTL, and cached response size up to 16 KiB. Capacity exhaustion is rejected rather than evicting active protection. Pending/ambiguous requests and oversized uncached responses are not automatically executed again. A completed cached response includes `X-TxBridge-Idempotent-Replay: true` when replayed.

This is bounded deduplication, not end-to-end exactly-once processing. A process can die after an upstream action but before recording its response. txAdmin can save a ban and then report that in-game delivery failed. Timeout does not prove nonexecution. Reconcile actual state or ask an operator before issuing a replacement operation with a new key. Records do not protect a retry after expiry or loss of persistence.

## Webhook signature

Webhook transport is a separate protocol using an independent secret per destination. Headers:

```text
X-TxBridge-Server: main
X-TxBridge-Event: main-123
X-TxBridge-Timestamp: <current send-attempt time>
X-TxBridge-Signature: <lowercase hex HMAC>
```

Canonical string (five LF-separated lines, no trailing LF):

```text
TXBRIDGE-WEBHOOK1
<serverId>
<eventId>
<timestamp>
<lowercase hex SHA256 of exact webhook body>
```

Verify HMAC and timestamp **before** processing JSON. Compare signature bytes without early-exit string comparison. The supplied WordPress receiver then checks schema/IDs and stores the event with a unique `(server_id, event_id)` constraint and body digest. A duplicate with identical body is acknowledged; the same ID with changed contents is rejected.

Each delivery attempt signs the same event body with a fresh timestamp. An older `emittedAt` is valid for a delayed queued event; freshness is based on the source timestamp, not receipt time. No request nonce is necessary for this webhook protocol because the persistent event ID/digest is the deduplication key. There is no signed response protocol; authenticated TLS protects the acknowledgment channel.

## Secret rotation

API clients may be added under a second key ID for a staged rotation. Deploy the new client/secret, switch the application, verify, then remove the old grant. Webhook receivers currently accept one configured secret per server; coordinate sender/receiver rotation, monitor transient authentication failures, and explicitly retry dead letters after repair. Event bodies need not change. Rotating the pseudonym key changes identifier correlations and requires a privacy/consumer migration decision.
