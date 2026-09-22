# Installation and first connection

## 1. Requirements and deployment choice

The resource targets the server-side FiveM Lua 5.4 runtime and uses the built-in JSON encoder, resource KVP persistence, HTTP natives, and documented server events. txAdmin must manage the running server for its events to arrive. No QBCore/ESX dependency is required. Native message/announcement actions specifically require the standard `chat` resource; custom chat frameworks need their own server integration.

The WordPress plugin targets PHP 8.1+ and WordPress 6.0+ APIs. Those minimum versions describe the intended API baseline, not a certification across all versions or plugins. This package was checked with PHP 8.4.23 and test doubles, not a running WordPress installation. Activate separately per site; network-wide multisite provisioning is not implemented.

Choose one of two deployments:

**Outbound only:** FiveM sends signed events/status snapshots to WordPress. Set `Config.Http.enabled = false` when you do not need remote reads or actions. No inbound txBridge proxy or txAdmin credentials are needed. WordPress can display the stored player-count snapshot.

**Bidirectional:** Keep the resource HTTP API enabled behind a restricted TLS proxy. WordPress signs server-side API requests. The public website never receives an API secret.

## 2. Install the resource and configure secrets

Copy the folder so the manifest is at `resources/[local]/txbridge/fxmanifest.lua`. Keep the name `txbridge` when using the examples. Do not install the entire repository as one FiveM resource.

Generate three independent secrets, running this command separately for each:

```sh
openssl rand -hex 32
```

Use one API secret, one webhook secret, and a separate pseudonym secret. The resulting 64 hexadecimal **characters are the literal shared-secret string**; do not decode them into bytes in your application.

Merge this before `ensure txbridge` in `server.cfg`:

```cfg
set txbridge_server_id "main"
set txbridge_wordpress_secret "YOUR_GENERATED_API_SECRET"
set txbridge_webhook_secret "YOUR_GENERATED_WEBHOOK_SECRET"
set txbridge_privacy_secret "YOUR_GENERATED_PSEUDONYM_SECRET"
set txbridge_webhook_url "https://www.example.com/wp-json/txbridge/v1/webhook"
ensure txbridge
```

Replace every placeholder; they are intentionally rejected as credentials in the supplied examples. Use **`set`**, never the public/server-info `sets` or replicated `setr` variants, for secrets. Restrict filesystem access and do not commit the actual configuration. The pseudonym secret is never needed in WordPress.

`serverId` must be unique per actual server, contain only letters/digits/underscore/hyphen, and be 1–64 characters. Preserve KVP storage across ordinary restarts. When cloning a server, wiping persistence, or restoring an old sequence counter, provision a new server ID and reconcile consumers. Reusing an old ID/counter can collide with events already stored in WordPress.

Run the local console command `txbridge_status` after starting. It reports sequence/queue counts, never credentials. Missing API client secrets prevent that client from authenticating. An invalid configured webhook URL or secret causes initialization to fail instead of silently sending unprotected data.

## 3. Install WordPress

Upload `txbridge-wordpress-0.1.0.zip` through Plugins → Add New → Upload Plugin, or copy `wordpress/txbridge-wordpress` into `wp-content/plugins`. Activate it. Activation creates the prefixed `txbridge_events` table and schedules daily retention cleanup.

Add the following to `wp-config.php` before the final stop-editing comment, inside its existing PHP block:

```php
define('TXBRIDGE_SERVERS', [
    'main' => [
        'url' => 'https://bridge.example.com/txbridge',
        'key_id' => 'wordpress',
        'secret' => 'YOUR_GENERATED_API_SECRET',
        'webhook_secret' => 'YOUR_GENERATED_WEBHOOK_SECRET',
        'public_status' => false,
        'label' => 'My Roleplay Server',
    ],
]);
define('TXBRIDGE_ALLOW_INTERNAL_PROXY', false);
define('TXBRIDGE_RETENTION_DAYS', 30);
define('TXBRIDGE_DELETE_DATA_ON_UNINSTALL', false);
```

The array key `main` must equal FiveM's `txbridge_server_id`. `key_id` must match `Config.Clients.wordpress`. The webhook signing secret must match on both sides. The URL is the **bridge** base, including `/txbridge`; it is not the txAdmin panel URL. With outbound-only delivery, the client base is unused until you call a private bridge request.

Use the canonical HTTPS webhook URL directly, without a redirect from another domain or trailing-slash rewrite. Keep the endpoint reachable by server-to-server POST requests; do not put a browser challenge or interactive login in front of it. Requests without a valid signature must still fail.

Within a snapshot interval, Tools → txBridge should show a recent observation. Default snapshots are emitted at startup and every 30 seconds. A stale snapshot means telemetry is unavailable, not proof that FXServer is stopped.

## 4. Add a public widget deliberately

Set the relevant server's `public_status` to `true`, then add this shortcode to a WordPress page:

```text
[txbridge_status server="main"]
```

Only label, server ID, player count, capacity, freshness, and observation time become public. Names, identifiers, moderation actions, audit entries, and raw txAdmin results remain private. The browser polls the limited WordPress status endpoint, not the FiveM private API.

## 5. Configure inbound HTTPS for the private API

The resource's route is on FXServer's HTTP listener:

```text
http://127.0.0.1:30120/txbridge/v1/status
```

Use your actual port. Copy and adapt `deploy/nginx.conf.example`. The example permits only the application's configured egress IP, terminates TLS, and forwards only `/txbridge/` to the local FXServer HTTP listener. It intentionally does not proxy the txAdmin panel.

Keep `Config.Http.allowedPeers` limited to the actual proxy socket address. Local Nginx uses `127.0.0.1`/`::1`; a container or other host usually has a different private source address. Add that precise trusted address, not `0.0.0.0`, a browser IP, or an `X-Forwarded-For` value. txBridge ignores forwarded-IP headers. Changing this table requires restarting the resource.

The `proxy_pass` example has **no trailing slash** so `/txbridge/` reaches FXServer. FiveM then supplies the resource-relative `/v1/...` target to Lua. Do not rewrite the URI to a different spelling, reorder query arguments, or drop signature headers.

Test your real proxy configuration before reloading it. Your game TCP/UDP ports may remain publicly accessible for players; txBridge's own peer allowlist must still reject direct calls that bypass the proxy. Restrict port 40120/txAdmin separately with a firewall/private network. An HTTPS proxy alone does not secure an otherwise reachable admin panel.

## 6. Make the first authenticated read

From the application host or approved proxy peer:

```sh
export TXBRIDGE_URL='https://bridge.example.com/txbridge'
export TXBRIDGE_SERVER='main'
export TXBRIDGE_KEY='wordpress'
# Enter the existing API secret without placing it in shell history:
read -rs TXBRIDGE_SECRET; export TXBRIDGE_SECRET; printf '\n'
python3 tools/txbridge_cli.py GET /v1/status
python3 tools/txbridge_cli.py GET /v1/capabilities
```

The CLI requires Python 3.10+ and only the standard library. It refuses redirects. For a test run on the FXServer host only, you may explicitly use `--url http://127.0.0.1:30120/txbridge --allow-loopback-http`. Do not use public plaintext HTTP.

A successful response has `ok: true`. An unsigned request should fail; that is expected, including for `/v1/health`. Synchronize both system clocks before diagnosing signature failures.

## 7. Enable a narrowly scoped action

For native private chat, enable `Config.Actions.message = true` and `Config.Clients.wordpress.scopes['actions:message'] = true`; restart the resource. The `chat` resource must be started.

Read `/v1/players`, then copy the intended player's current `sessionId` into `examples/native-message.json`. Send:

```sh
python3 tools/txbridge_cli.py POST /v1/players/12/actions/message \
  --body-file examples/native-message.json \
  --idempotency-key message_demo_20260922_001
```

Use the actual player ID, not 12 blindly. Retrying the same operation uses the same body and idempotency key, but a fresh signature/nonce; the CLI generates those. A new intentional operation needs a different idempotency key. A disconnected/reused player ID will be rejected if the session ID changed.

## 8. Optional host status

Configure a fourth independent secret as `TXHOST_API_TOKEN` in the environment of the **txAdmin process**. Set its matching value in `txbridge_txadmin_host_token`, enable `Config.TxAdmin.hostStatusEnabled`, and grant `txadmin:host` to the API client. Restart the appropriate processes to load those settings. Call `/v1/txadmin/host/status`.

Use the `x-txadmin-envtoken` header (the bridge does this), not a URL token. Do not set the upstream token to `disabled`. Leave the internal session adapter off unless you have read its separate compatibility and risk section.

## 9. Staging acceptance before production

Complete [Testing and acceptance](TESTING.md): signed reads, forbidden direct peers, txAdmin event delivery, stale status, resource restarts, retry/deduplication, KVP persistence, storage errors, permissions, and one explicitly approved action. This package has not been deployed to your server or linked to your real WordPress site.
