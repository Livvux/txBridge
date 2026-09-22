# Security, operational limits and failure recovery

## Deployment boundary

Default configuration is read-only, with only actual loopback API peers accepted, no raw identifiers, all native writes disabled, and the internal txAdmin adapter disabled. WordPress public status is separately disabled. An unconfigured secret is not a guest account.

Use HTTPS, a minimal peer/IP allowlist, per-application secrets and scopes, exact route/resource grants, and least-privilege txAdmin permissions. Keep txAdmin and its data directory private. Do not use txAdmin's private intercom token as a generic integration API key, disable upstream authentication, forge NUI administrator headers, or expose developer/debug routes.

HMAC is not encryption; the private proxy-to-FXServer hop is trusted. TLS authenticates webhook acknowledgments and upstream server responses. URL configuration is operator-controlled; request bodies cannot redirect calls to arbitrary hosts. Outbound redirects are not followed. The code is not a defense against a compromised FXServer host, WordPress administrator, another malicious installed server resource, or a hostile hosting operator with filesystem/console access.

The native API has no arbitrary console command endpoint. However, **explicitly enabling internal txAdmin command/master/config/deployer routes can grant equivalent or greater authority**. An exact route rule still leaves allowed query/body inputs under that client's control. It is not safe to grant such a scope to ordinary website users or a broad automation key.

## Limits and defaults

| Control | Default |
|---|---:|
| Inbound JSON body | 32 KiB |
| Body receive timeout / pending body slots | 5 seconds / 16 |
| Rate refill and burst | 120 requests/minute / 30 per peer and client bucket |
| Rate bucket capacity | 256 |
| Signature clock skew | 90 seconds |
| Retained nonce capacity | 2,048 |
| Idempotency entries / retention | 512 / 24 hours |
| Cached idempotent response | Up to 16 KiB |
| Event payload before envelope | 8 KiB; oversized content becomes a truncation marker |
| Event history / age | 200 events / seven days, whichever removes first |
| Local audit entries | 200 |
| Queued deliveries / dead letters | 500 / 100 |
| Delivery attempts / age | Eight / 24 hours |
| Native HTTP request timeout / outstanding requests | Ten seconds / four |
| Status interval | 30 seconds; configuration minimum ten seconds |
| Upstream txAdmin response | 256 KiB post-receive application check |
| WordPress accepted webhook / client response | 32 KiB / 512 KiB |
| WordPress inbox retention | 30 days by default |

With default 30-second status snapshots alone, 200 retained events represent roughly 100 minutes, not seven guaranteed days. At that rate, a 30-day WordPress inbox can hold around 86,400 status records **per server**, plus all other events. Size your database, consider longer snapshot intervals and narrower event filters, and monitor cleanup/queue lag. The stock public freshness threshold is 90 seconds; changing the emission cadence may require a coordinated display policy change.

Rate limits behind a shared local proxy may aggregate several applications into the same peer bucket. Tune deliberately; do not remove peer authentication or bounds to conceal overload. The resource checks body size after receiving native data as well as Content-Length; the reverse proxy's body limit is the earlier network-facing bound. The upstream response-size limit is not a streaming memory cap.

## Durability and ordering

The Lua implementation stores a bounded JSON journal in resource KVP. Events, outbox entries and the sequence live together; replay/idempotency stores are also persistent. It rewrites bounded documents rather than using a transactional message broker. This is intended for modest event volume, not an unlimited high-throughput audit pipeline. KVP calls do not provide an application-level fsync or multi-store transaction guarantee.

There is no end-to-end exactly-once delivery guarantee. Retried webhook events can arrive more than once and out of order. WordPress deduplicates accepted IDs/bodies, but its post-insert application hook is not transactional with billing, moderation or another service. A source process can disappear before emitting an event, or before a delivery succeeds. Do not claim that a webhook is an authoritative replica of the txAdmin database.

Preserve KVP and server identity across ordinary restarts. Protect backups and restore procedures. Reusing an old sequence under the same server ID can collide with WordPress's deduplication key. Allocate a new ID when resetting/restoring an old timeline, and migrate consumers explicitly. A corrupt JSON KVP store causes startup failure rather than silently erasing evidence. Structurally invalid/missing persistence or storage failures need operator repair and backups, not blind deletion.

The local audit is bounded, mutable by the host operator, and not tamper-proof. Ship separately to an access-controlled audit store when independent evidence is required. Do not log raw request headers, cookies, shared secrets, full upstream payloads, or console commands.

## Upstream timeouts and partial success

FiveM's HTTP callback cannot be reliably canceled by this Lua wrapper. The bridge can return a timeout and ignore a late result, but it continues counting the outstanding native request until its callback arrives. This prevents unlimited timed-out native requests; it can also exhaust available slots if callbacks never return. Alert on outstanding requests/timeouts and investigate the network/runtime before restarting the bridge to clear accounting.

A txAdmin warning or ban may be saved before an in-game notification fails. HTTP 200 may carry an application error. A resource restart may stop a resource but fail to start it. An FXServer stop/restart can kill the bridge before its action acknowledgment arrives. Always reconcile actual state on ambiguous outcomes. Never create a new idempotency key simply to force a previously uncertain destructive operation to run again.

## Privacy

Default event redaction removes player/admin names, message/reason text and console commands. Identifiers are pseudonymized or redacted; IPs and hardware tokens are not exposed through the normal API. Pseudonymized identifiers, timestamps, net IDs, operation types and activity patterns may still identify/link people. Turning on names, text or raw identifiers increases the sensitivity of the WordPress inbox and all receivers.

The separate `players:identifiers` scope also requires a privacy opt-in. Internal txAdmin responses bypass event sanitization and may contain full personal or sensitive operational records. Do not send them to public status endpoints. Free-text content can contain personal information even when its field is not an identifier.

Apply your organization's access, deletion, backup and retention policies to WordPress's table, FiveM KVP, external logs and consumer databases. This document does not determine your legal basis, consent obligations or retention requirements.

## Recovery checklist

For signature errors, verify matching server/key IDs and independent directional secrets, synchronized clocks, exact path/body serialization, preserved headers, and lack of redirects. Do not disable authentication to debug.

For no events, verify the resource is started, txAdmin is actually managing the server, the canonical HTTPS webhook URL, the WordPress plugin/table, and local queue/error counters. `txbridge_status` is a safe first diagnostic.

For delivery failures, repair TLS/DNS/network/receiver/configuration first, inspect retained dead-letter metadata with an authorized client, then explicitly retry selected deliveries. Check whether a hook needs its own inbox-based recovery even after webhook acceptance. Deduplication prevents an identical delivery from rerunning a failed hook.

For a txAdmin upgrade, disable experimental routes, compare the new source surface and handler/auth semantics, renew an authorized limited session only if needed, then repeat staging tests. A passing surface-name audit alone is insufficient.
