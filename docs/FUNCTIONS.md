# Public functions and code organization

## FiveM resource exports

All exports are server-side. No client script or privileged net event is installed.

| Export | Inputs | Return | Access and meaning |
|---|---|---|---|
| `GetStatus()` | None | Status table | Copied current bridge/native snapshot |
| `GetCapabilities()` | None | Capabilities table | Copied flags, event names and limits |
| `GetPlayers()` | None | Array of player objects | Copied, privacy-filtered connection list |
| `PublishEvent(name, data)` | Bounded event name and Lua table | Event ID, or `nil, error` for rejected publisher/input | Exact calling resource must be in `Events.allowedPublishers` |

Example from another server resource:

```lua
local status = exports.txbridge:GetStatus()
local players = exports.txbridge:GetPlayers()
local id, err = exports.txbridge:PublishEvent('queue.updated', {
    waiting = 12,
    estimatedWaitSeconds = 90,
})
if not id then print(err or 'publish failed') end
```

`PublishEvent` uses the `custom.` namespace and checks `GetInvokingResource()`. Grant a publisher explicitly, for example `Config.Events.allowedPublishers['my_queue'] = true`. Event names begin with a letter, contain only letters/digits/underscore/dot/hyphen, and are at most 100 characters before the prefix. Table contents must be safe to persist/share. Storage faults can raise an error; important callers should handle failures rather than assuming acceptance.

Read exports return copies, not references that mutate bridge state. These exports are available to trusted server resources; they are not a security sandbox against a malicious resource installed by the server owner.

## Local diagnostic command

`txbridge_status` is registered as a restricted command and also checks console source `0`. It logs version, configured server ID, event sequence, queue/dead-letter and dropped counts. It does not print credentials. There are no resource-level commands for arbitrary console execution, offline process start or txAdmin login.

## Lua modules and internal functions

Only the exports and documented HTTP protocols are application interfaces. Internal `TxBridge.*` helpers can change between releases; do not call them from unrelated resources.

| File | Responsibility / important internal entry points |
|---|---|
| `fxmanifest.lua` | Server-only load order; no framework/client dependency |
| `config.lua` | Client grants, peers, privacy, action flags, delivery policy, optional upstream rules |
| `server/crypto.lua` | Pure Lua SHA-256, HMAC-SHA256 and signature comparison |
| `server/core.lua` | JSON helpers, KVP journal, pseudonyms/redaction, status/players/resources, session IDs and URL checks |
| `server/security.lua` | Header/peer parsing, rate limits, request authentication, scopes and persistent idempotency |
| `server/catalog.lua` | Pinned txAdmin route metadata and classifications |
| `server/transport.lua` | Bounded native HTTP requests, persistent enqueue/pump/retry/dead-letter handling |
| `server/events.lua` | Documented schema selection, trusted event capture, publication and FiveM lifecycle observations |
| `server/txadmin.lua` | Named internal-route adapter, host status, exact grants and upstream error handling |
| `server/api.lua` | Request parsing, dispatch, validation, native actions and response envelopes |
| `server/main.lua` | Startup validation, HTTP handler, exports, local command and background loops while FXServer runs |

The loops are ordinary running-resource tasks, not a separate process. They stop with the resource/FXServer. No invisible external scheduler is installed.

## WordPress application interfaces

| Interface | Purpose |
|---|---|
| `TXBridge_Client::request(...)` | Server-side signed bridge request; returns `WP_REST_Response` or `WP_Error` |
| `txbridge_event` action hook | Receives the first stored event and server ID; nontransactional extension point |
| `[txbridge_status server="..."]` | Opt-in public, limited status widget |
| REST `/admin/events/{server}` | Durable inbox access for an authorized consumer |
| REST `/admin/request/{server}` | Capability-checked server-side bridge call |

`TXBridge_Signing` encapsulates canonical request/webhook signing and verification. `TXBridge_WordPress` handles activation, retention, permission callbacks, receipt, snapshots, private endpoints, shortcode and Tools page. These implementation classes are not a promise to expose every method as a remote endpoint.

## Other applications

Use the standard-library Python client as a reference for Node, Laravel, Django, n8n or another backend. A receiver needs exact-byte webhook HMAC verification, a freshness window, persistent event-ID/digest deduplication, and a deliberate retention policy. A sending application needs a fixed HTTPS bridge base, a dedicated client ID/secret/scope set and the request-signing protocol. Do not distribute those secrets to browsers/mobile game clients or untrusted workflow viewers.

Add another `Config.Clients` entry with a unique `secretConvar` and minimal scopes. For a second push destination, add a `Config.Webhooks` entry with a fixed URL convar, separate secret convar, and event-type allowlist. An event filter can use `events = { ['bridge.status'] = true }` rather than `['*']` for a status-only consumer.
