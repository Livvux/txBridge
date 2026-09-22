# Event reference and delivery

All 17 current documented txAdmin events are subscribed server-side using `AddEventHandler`, not `RegisterNetEvent`. The upstream prefix is `txAdmin:events:`. The external event type is `txadmin.<sameName>`. These notifications do not grant an application the ability to perform the original txAdmin action.

## Current upstream events

| Upstream name after prefix | Documented payload fields |
|---|---|
| `announcement` | `author`, `message` |
| `serverShuttingDown` | `delay`, `author`, `message` |
| `scheduledRestart` | `secondsRemaining`, `translatedMessage` |
| `scheduledRestartSkipped` | `secondsRemaining`, `temporary`, `author` |
| `playerBanned` | `author`, `reason`, `actionId`, `expiration`, `durationInput`, `durationTranslated`, `targetNetId`, `targetIds`, `targetHwids`, `targetName`, `kickMessage` |
| `playerDirectMessage` | `target`, `author`, `message` |
| `playerHealed` | `target`, `author` |
| `playerKicked` | `target`, `author`, `reason`, `dropMessage` |
| `playerWarned` | `author`, `reason`, `actionId`, `targetNetId`, `targetIds`, `targetName` |
| `whitelistPlayer` | `action`, `license`, `playerName`, `adminName` |
| `whitelistPreApproval` | `action`, `identifier`, `playerName`, `adminName` |
| `whitelistRequest` | `action`, `playerName`, `requestId`, `license`, `adminName` |
| `actionRevoked` | `actionId`, `actionType`, `actionReason`, `actionAuthor`, `playerName`, `playerIds`, `playerHwids`, `revokedBy` |
| `adminAuth` | `netid`, `isAdmin`, `username` |
| `adminsUpdated` | Array of online admin net IDs |
| `configChanged` | No payload |
| `consoleCommand` | `author`, `channel`, `command` |


Only these selected documented keys are forwarded from current events; unknown new keys do not silently leak into external applications. The table lists the original schema, **not a promise of unredacted values**. Null/optional values may be omitted by the Lua JSON conversion.

`expiration: false` means a permanent ban. Player ban/warn notifications may refer to offline identifiers rather than a live net ID. `playerHealed.target` and `playerKicked.target` can be `-1` for everyone. `adminAuth.netid = -1` revokes the observed admin set. Never interpret those values as normal connected-player IDs.

Allowlist-related action variants are `added`/`removed` for `whitelistPlayer` and `whitelistPreApproval`, and `requested`/`approved`/`denied`/`deniedAll` for `whitelistRequest`. Optional names, request IDs and licenses are not present for every variant. The event named `whitelistPlayer` does not cover all preapproval/request transitions: all three families are captured.

Deprecated names, off by default: `playerWhitelisted`, `healedPlayer`, `skippedNextScheduledRestart`. `Config.Events.captureDeprecated = true` enables them for older installations. They retain their original names; modern aliases can produce duplicate observations. This option is not a full historical-schema compatibility layer.

## Privacy defaults

Player/admin names, messages/reasons, and console-command text are redacted by default. Identifier fields become keyed HMAC pseudonyms when a separate privacy secret is configured; without it they are `[redacted]`. Hardware-token fields and explicitly prohibited credential/IP fields remain redacted. Pseudonyms are still linkable data, not guaranteed anonymous data.

Enable individual `Config.Privacy` fields only after deciding who needs those data and for how long. Redaction happens before normal event persistence/delivery. Oversized payloads are replaced by a truncation marker; deep objects and long strings/collections are bounded. Custom publishers are trusted code: arbitrary secret-bearing property names cannot be recognized by a generic sanitizer. Do not publish secrets or raw sensitive data at all.

The experimental upstream API does **not** use event redaction. Its privileged responses may contain full txAdmin records; isolate it from public UI and low-trust clients.

## Event envelope

```json
{
  "version": 1,
  "id": "main-123",
  "sequence": 123,
  "serverId": "main",
  "type": "txadmin.scheduledRestart",
  "origin": "txadmin_event",
  "emittedAt": 1780000000,
  "data": {
    "secondsRemaining": 60,
    "translatedMessage": "[redacted]"
  }
}
```

Timestamps are Unix seconds. The example time is illustrative, not a current request timestamp. `sequence` is monotonic within the persisted server identity. `origin` distinguishes a txAdmin notification, a FiveM event, the bridge itself, or an approved local publisher. Consumers should preserve and deduplicate by `(serverId,id)`.

Additional implemented types:

| Family | Types |
|---|---|
| FiveM observations | `fivem.playerJoined`, `fivem.playerDropped`, `fivem.resourceStarted`, `fivem.resourceStopped` |
| Bridge telemetry/actions | `bridge.started`, `bridge.status`, `bridge.announcement`, `bridge.playerKicked`, `bridge.playerMessaged`, `bridge.resourceAction` |
| Trusted extension publisher | `custom.<name>` |

Resource stop/shutdown events are best-effort observations, not a guarantee that an HTTP webhook reaches WordPress before the process exits. Retained outbox items can be delivered on a later restart, subject to configured limits.

## Delivery policy

The default snapshot interval is 30 seconds. Normal events and an outbox share a bounded local KVP journal. One outbound attempt per destination is active at a time; other eligible items can overtake a failed/backed-off item. Each body is stable across retries, but timestamps/signatures are refreshed. Use source sequence for state comparisons, and receipt cursors to process every arriving message.

Defaults: 500 queued deliveries, 100 retained dead letters, eight attempts, 24-hour queued age, ten-second request timeout, at most four outstanding native HTTP requests, exponential backoff capped at five minutes. Transient HTTP 408/429/5xx and transport failures are retried. Most other 4xx responses become dead letters immediately. No redirect is followed. An HTTP 2xx acknowledgment means the destination accepted the delivery; arbitrary application hooks might still fail later.

Monitor `/v1/webhooks`, `/v1/webhooks/dead-letters` and `/v1/status`. After repairing an endpoint, use `/v1/webhooks/retry` with its retained `deliveryId`. Manual retry keeps the event ID/body but resets attempt and queue-age accounting. Queue/dead-letter overflow is counted; the storage is not unbounded and delivery is not guaranteed forever. Removing a destination or changing identity/retention requires an operational migration.

There is no full initial import, no historical ban/allowlist reconciliation, no durable event emission from a stopped FXServer, and no automatic replay from txAdmin's database. The observed admin/restart state starts incomplete each resource boot. A separate, authorized reconciliation service would be needed for authoritative offline state.
