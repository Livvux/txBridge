# WordPress integration reference

## Configuration and storage

The complete installable plugin is `wordpress/txbridge-wordpress`; the standalone plugin ZIP has that folder at its root. Runtime configuration lives in the `TXBRIDGE_SERVERS` constant in `wp-config.php`, not a public REST response or browser JavaScript. Use independent API and webhook secrets per server/connection. Multiple configured server IDs are supported in the map.

The plugin creates one table per WordPress site: `<prefix>txbridge_events`. Rows contain a local receipt ID, server ID, source event ID/sequence, type, source timestamp, receipt timestamp, payload digest, and sanitized payload. Server/event identity columns use an explicit case-sensitive ASCII collation, independent of the site's usual text collation. A unique `(server_id,event_id)` key deduplicates deliveries. No txAdmin database files are read, mounted or modified.

Retained payloads may still be personal/operational data. Daily cleanup uses `TXBRIDGE_RETENTION_DAYS` (30 by default, restricted to 1–365). WordPress's normal scheduled-task execution depends on site traffic/cron configuration; use a real scheduled WordPress cron invocation when retention timing matters. Deactivation unschedules cleanup. Uninstall preserves the table unless `TXBRIDGE_DELETE_DATA_ON_UNINSTALL` is explicitly true. Confirm retention and backup policies separately.

## REST endpoints

All paths below are under your site's normal `/wp-json/txbridge/v1` prefix.

| Method and route | Authentication | Purpose |
|---|---|---|
| `POST /webhook` | Webhook HMAC, timestamp and valid server mapping | Durable signed event inbox |
| `GET /status/{server}` | Public only when that server has `public_status: true` | Limited status projection |
| `GET /admin/events/{server}?after=0&limit=50` | WordPress authenticated `manage_options` | Private inbox consumption |
| `POST /admin/request/{server}` | WordPress authenticated `manage_options` | Server-side signed call to the fixed FiveM bridge |

For cookie-based WordPress REST authentication, send the standard WordPress REST nonce in addition to the logged-in cookie. Use WordPress's authenticated server-to-server mechanism for a trusted external administrative consumer; the plugin does not invent a second public admin password system. Granting `manage_options` is broad WordPress authority, so do not give it to ordinary website members merely for this feature.

### Webhook acceptance

The permission callback verifies HMAC before processing JSON. The receiver checks version 1, bounded identifiers/type, source sequence, matching body/header server/event IDs, reasonable source time, and object/array data. It performs a database insert before invoking custom application hooks.

First acceptance returns HTTP 202 with `accepted: true`. An identical duplicate returns 200 with `duplicate: true`. The same event ID with a different body returns 409. Storage failure returns 503 so a sender can retry. The source signature timestamp must be fresh even when the source event was emitted earlier.

### Public status

The projection includes only `serverId`, configured `label`, `state`, `players`, `maxPlayers`, `observedAt`, and `staleAfterSeconds`. It reads the highest-source-sequence `bridge.status` snapshot rather than letting a delayed lower-sequence event replace newer status. State is `unknown` before the first snapshot, `online` for a recent snapshot, or `stale` after 90 seconds.

A stale snapshot does not distinguish a stopped server from network failure, authentication error, queue delay or an inactive resource. Do not display stale cached player numbers as proof of a live server. The supplied shortcode says “Status unavailable” instead.

### Private inbox cursor

The admin events route uses the local **receipt ID** as `after`, not the source event sequence. Return shape:

```json
{
  "items": [{"receiptId":17,"event":{"id":"main-123"}}],
  "cursor":17
}
```

The event above is abbreviated. Persist the cursor only after processing the complete page. This cursor lets a consumer receive a late lower-source-sequence event that was inserted after a newer one. Use source sequence separately when deciding which observation represents the newest state. Retention expiration can still remove unread data; monitor lag and keep your own durable processing checkpoint/work queue.

### Private request wrapper

To read the server from an authenticated WordPress admin REST call, POST this JSON to `/admin/request/main`:

```json
{"method":"GET","path":"/v1/status"}
```

To execute an enabled native action, send `method: POST`, the relative bridge `path`, a JSON-object `body`, and a caller-owned `idempotencyKey`. You cannot supply a destination URL or headers. WordPress chooses the configured server URL and signs the request using the server-side secret. All Lua scopes/feature flags and player-session checks still apply.

Direct txAdmin internal proxying is rejected by WordPress unless `TXBRIDGE_ALLOW_INTERNAL_PROXY` is true, independently of the Lua opt-in. Leave that false for normal website integrations.

## PHP application client

```php
$result = TXBridge_Client::request('main', 'GET', '/v1/status');
if (is_wp_error($result)) {
    // Present a controlled error; do not dump secrets or request headers.
    return;
}
$http_status = $result->get_status();
$payload = $result->get_data(); // ['ok' => ..., 'data' => ...] or ['error' => ...]
```

Signature: `request(string $server, string $method, string $path, mixed $data = null, string $idem = '')`. Return value is `WP_REST_Response` or `WP_Error`, not a raw array. All POSTs require an explicit idempotency key. The client does not automatically repeat a timed-out write.

Configured bases must use HTTPS. The client rejects absolute/request-supplied destination paths, redirects, bodies on GET, invalid relative targets and oversized bodies. TLS verification remains enabled. Requests have a 15-second timeout and a 512 KiB response-read limit. Do not disable TLS checks to work around a bad certificate.

Call privileged operations only from your own capability-checked handlers/jobs. This client is not a frontend JavaScript SDK and does not turn every WordPress user into a FiveM administrator.

## Hook and extension example

```php
add_action('txbridge_event', function (array $event, string $server): void {
    if ($event['type'] !== 'txadmin.scheduledRestart') {
        return;
    }
    // Queue your own idempotent business operation or update a non-critical display.
}, 10, 2);
```

A full non-destructive example is in `examples/wordpress-consumer.php`. Hooks run after the first durable insert and are not rerun for identical delivery retries. A crash after insert/before hook, or a thrown exception in a hook, can leave downstream work incomplete. The inbox survives, but that does not create an exactly-once transaction with your external side effect. Build a separate durable consumer/reconciliation loop for billing, paid access, ban enforcement or other important state.

## Shortcode and administrator page

`[txbridge_status server="main"]` renders only for explicitly public servers. Its small script polls the public WordPress projection every 30 seconds with a five-second timeout, uses `textContent` for updates, and never embeds an API secret. Tools → txBridge shows connection observations and configuration guidance. There is no full browser-based txAdmin replacement, player moderation dashboard, WooCommerce provisioning workflow, account-linking flow or membership/allowlist synchronization included in version 0.1.0.
