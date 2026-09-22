# Lua HTTP API

External base: `https://bridge.example.com/txbridge`. Resource-relative paths below are used in signatures. Every route requires HMAC authentication, actual-peer permission, and its listed scope. Every POST also requires an idempotency key. Configuration flags and upstream permissions are additional restrictions, not replacements for scope checks.

## Read operations

| Method and path | Scope | Response data / behavior |
|---|---|---|
| `GET /v1/health` | `status:read` | `healthy`, `serverId`; still private/authenticated |
| `GET /v1/status` | `status:read` | Current player count, capacity, hostname, resource uptime, monitor state, queue metrics |
| `GET /v1/capabilities` | `status:read` | Event names, feature flags, privacy flags and explicit guarantee limitations |
| `GET /v1/players` | `players:read` | `items[]`: numeric `id`, `sessionId`, privacy-filtered `name`, `ping` |
| `GET /v1/players/{id}/identifiers` | `players:identifiers` | Requires `Privacy.exposeIdentifiers`; only configured identifier types, never IP |
| `GET /v1/resources` | `resources:read` | `items[]`: resource `name` and runtime `state` |
| `GET /v1/events?after=0&limit=50` | `events:read` | Bounded source-sequence feed and gap indicator; never a complete database |
| `GET /v1/audit` | `audit:read` | Private bounded local action audit; `tamperProof: false` |
| `GET /v1/webhooks` | `webhooks:read` | Queue/endpoint operational metadata, no configured URLs or secrets |
| `GET /v1/webhooks/dead-letters` | `webhooks:read` | Failed-delivery metadata; no raw payloads |
| `GET /v1/txadmin/state` | `events:read` | Only state observed since this resource started; `authoritative: false` |
| `GET /v1/txadmin/routes` | `status:read` | 58-route inventory and adapter metadata, not an authorization grant |
| `GET /v1/txadmin/host/status` | `txadmin:host` | Optional upstream `/host/status`, requiring its separately configured token |

`bridgeUptimeSeconds` means uptime of this resource instance, not host/FXServer/txAdmin process uptime. `processState: running` only means the current request is being served by the running game process. CPU, total host memory and historical player playtime are not fabricated from these native reads.

The native player list exposes connection-local player IDs, not persistent accounts. Names are `[redacted]` by default. The raw-identifier endpoint is an explicit privacy exception; it does not contain txAdmin's offline player database or hardware tokens.

## Native and transport actions

| Method and path | Scope | JSON body | Required configuration |
|---|---|---|---|
| `POST /v1/actions/announce` | `actions:announce` | `{"message":"..."}` | `Actions.announce`, started `chat` |
| `POST /v1/players/{id}/actions/message` | `actions:message` | `{"sessionId":"...","message":"..."}` | `Actions.message`, started `chat` |
| `POST /v1/players/{id}/actions/kick` | `actions:kick` | `{"sessionId":"...","reason":"..."}` | `Actions.kick` |
| `POST /v1/resources/{name}/actions/start` | `actions:resource` | `{}` | `Actions.resources` and exact resource allowlist |
| `POST /v1/resources/{name}/actions/stop` | `actions:resource` | `{}` | Same; protected resources rejected |
| `POST /v1/resources/{name}/actions/restart` | `actions:resource` | `{}` | Same; partial transitions reported |
| `POST /v1/webhooks/retry` | `webhooks:write` | `{"deliveryId":"..."}` | Existing retained dead letter and configured endpoint |
| `POST /v1/txadmin/request` | `txadmin:<routeId>` | Named route request described below | Experimental adapter, exact rule, pinned revision acknowledgement, session |

Messages/announcements must be 1–512 bytes and contain visible text; kick reasons are 1–256 bytes. Control characters/newlines are rejected. Unknown body fields are rejected. Player actions require the exact current `sessionId` obtained from `/v1/players`, so a reused net ID is not sufficient authorization to affect a replacement player.

Native messages use `chat:addMessage`; native kicks use `DropPlayer`. They return `txAdminAction: false` and do **not** create txAdmin warnings, bans, allowlist entries or admin-history records. An emitted `bridge.playerKicked` observation is not a txAdmin database action. A chat send response is not a client-render acknowledgment.

Only resource names made of letters/digits/underscore/hyphen are accepted. `monitor`, the bridge itself, and the configured protected-resource set cannot be controlled. Restart is a stop/start transition, so an error can leave a resource stopped; inspect the returned result. There is no general arbitrary `ExecuteCommand` or RCON endpoint in the native API.

## Event cursor response

```json
{
  "ok": true,
  "data": {
    "items": [],
    "cursor": 120,
    "latest": 120,
    "oldestAvailable": 1,
    "gap": false,
    "authoritative": false
  }
}
```

The values above are illustrative. `after` is a nonnegative source event sequence not greater than the current sequence. `limit` is 1–100. Store the returned cursor after processing a page. When `gap` is true, retained history no longer reaches the requested cursor: alert/reconcile instead of assuming nothing happened. `GET /v1/txadmin/state` and cursor replay cannot recover txAdmin changes made while the resource was offline.

Do not confuse this origin-sequence cursor with WordPress's **receipt-ID cursor**, which handles out-of-order webhook arrival.

## Experimental request wrapper

```json
{
  "route": "player_stats",
  "params": {},
  "query": {}
}
```

The bridge resolves method and path from the audited catalog. Optional `body` is supplied only for upstream POST routes. `params` must exactly match a locally configured rule; it is not a wildcard. Query keys/values are bounded and scalar; they are deterministically percent-encoded upstream. The caller cannot choose a destination host, authentication header, or arbitrary URI.

Upstream JSON is returned inside `data.upstream`; it is not converted into a stable schema. HTML/log responses are returned as inert `data.text` with `interpretation: unverified_text`, not rendered or considered a verified successful business action. See the upstream coverage reference before enabling this facility.

## Response envelopes and errors

```json
{"ok":true,"data":{"serverId":"main","players":12,"maxPlayers":48}}
```

```json
{"ok":false,"error":{"code":"forbidden","message":"..."}}
```

The success example is abbreviated. Consumers should check HTTP status **and** `ok`, not merely whether JSON was returned. Typical errors:

| HTTP status | Meaning |
|---|---|
| 400 | Invalid JSON, shape, target, cursor, length or input |
| 401 | Missing/invalid signature or stale timestamp |
| 403 | Peer/scope forbidden, disabled feature, protected resource, blocked upstream route |
| 404 / 405 | Unknown route/player/resource or unsupported HTTP method |
| 408 / 413 / 415 | Body timeout, body too large or wrong content type |
| 409 | Replayed nonce, idempotency conflict/pending/uncached response, player session changed, unavailable chat, partial resource failure |
| 429 | Request rate limit; inspect the actual error code |
| 500 / 503 | Local error, configuration/storage fault, replay/idempotency/HTTP capacity or missing integration configuration |
| 502 / 504 | Upstream rejection/application failure, transport failure or timeout; an action may already have occurred |

Errors do not expose Lua stack traces or request secrets. Internal txAdmin error objects are privileged upstream data and can contain personal/operational information. No-store/nosniff headers are used on ordinary API responses. The machine-readable OpenAPI files document all 21 concrete method/path operations; they do not pretend that the internal upstream contracts are stable.
