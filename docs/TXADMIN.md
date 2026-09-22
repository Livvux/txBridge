# txAdmin integration and complete router inventory

## Three distinct integration surfaces

**Documented notifications:** the 17 current server events are captured through FiveM. This is the normal, credential-free txAdmin integration. They are not callable administration functions, and they can be missed when the game process/resource is offline.

**Host status:** `/host/status` is a separate host-facing route using `TXHOST_API_TOKEN` and `x-txadmin-envtoken`. txBridge implements a private scoped read adapter. It does not assume that this token authorizes player actions or the panel's other routes. The upstream handler returns `txManager.hostStatus`; its object is passed through rather than replaced with an invented universal schema.

**Internal panel routes:** txAdmin's web application has its own session-authenticated routes. The pinned middleware checks the authorized admin session and, for web API requests, `x-txadmin-csrftoken`. They are not a stable third-party API contract. An opt-in bridge adapter can address 42 inventoried templates, subject to txAdmin permissions and per-route local configuration.

## What “all endpoints” covers here

The inventory below includes **all 58 HTTP registrations in `core/modules/WebServer/router.ts` at the audited commit**, including two conditional development registrations. It is not all txAdmin source functions, static files/SPA middleware, WebSocket channels, every dynamic action's complete schema, or future additions. No claim is made that all 42 experimental templates have been exercised against a live txAdmin installation.

Every inventoried route has a named classification:

| Classification | Count | Treatment |
|---|---:|---|
| Experimental panel route | 42 | Generic named-route adapter, off by default |
| Authentication lifecycle | 11 | Documented only; no account creation, login automation or credential-management bridge |
| Host status | 1 | Separate token-authenticated read adapter |
| Private intercom | 2 | Explicitly blocked; no extraction or reuse of monitor's private token |
| Development-only | 2 | Explicitly blocked |

Browser-only/rendered routes are returned as inert text when enabled. Binary/streaming download workflows, browser redirects and interactive flows are not implemented. A route being in the catalog does not mean its every operation makes sense from a Lua resource. For example, a stop/restart request can kill the bridge before its response is delivered, and a stopped FXServer cannot receive a later start request through that resource.

## Enabling one experimental read

First match your installed txAdmin to the audited source and review the exact handler, auth middleware, and permissions. The release is pinned to:

```text
8a9a41410000fd92a527fe11bae2b8eeeb8b10e0
```

Set the acknowledgement convar to that exact value only after that review; it is a human acknowledgement, **not automatic detection of the installed build**. The adapter does not become compatible merely because this string is configured.

Create/use an authorized, least-privilege txAdmin admin account under your control. Obtain its current browser-session Cookie header and CSRF token from your own authenticated session. Store those only in private server configuration. This bridge deliberately does not collect passwords or automate login. Session invalidation/expiry will require operator renewal.

Before `ensure txbridge`, add:

```cfg
set txbridge_txadmin_url "http://127.0.0.1:40120"
set txbridge_txadmin_revision "8a9a41410000fd92a527fe11bae2b8eeeb8b10e0"
set txbridge_txadmin_cookie "YOUR_AUTHORIZED_SESSION_COOKIE_HEADER"
set txbridge_txadmin_csrf "YOUR_AUTHORIZED_SESSION_CSRF_TOKEN"
```

In `config.lua`, change only the required grants:

```lua
-- Merge into the existing configuration, not a second Config object.
Config.TxAdmin.experimental = true
Config.TxAdmin.rules = {
    { route = 'player_stats', params = {} },
}
Config.Clients.wordpress.scopes['txadmin:player_stats'] = true
```

For WordPress-originated requests, additionally set `TXBRIDGE_ALLOW_INTERNAL_PROXY` to `true`. Restart the resource to reload Lua configuration. Send a signed POST to the bridge:

```sh
python3 tools/txbridge_cli.py POST /v1/txadmin/request \
  --body-file examples/txadmin-player-stats.json \
  --idempotency-key txadmin_stats_demo_20260922_001
```

Even though this wrapper calls an upstream GET, the wrapper is POST and therefore needs its own idempotency key. Do not reuse the example key for later intentional reads, or you may receive its retained result instead of a new one.

## Exact parameter grants

A dynamic route grant must match the complete `params` object, not just the template. For example:

```lua
{ route = 'whitelist_list', params = { table = 'requests' } }
```

permits the upstream `/whitelist/requests` path, not `/whitelist/approvals`. The client also needs `txadmin:whitelist_list`. Query and JSON body remain caller inputs within transport limits; route grants are **not field-level policy rules**. In particular, giving a route access to arbitrary commands, settings, setup, master actions, deployment, bans or mass allowlist changes is very powerful even with a fixed action parameter. Use separate clients, minimum txAdmin permissions, and an application approval policy.

No URL, Cookie, CSRF token, intercom token, or alternative destination host is accepted from an inbound request. Authentication lifecycle, intercom and development routes remain blocked regardless of configured grants.

## Verified dynamic player/allowlist actions

The following action names and basic inputs were read in the pinned handlers. These are compatibility notes, not an exhaustive normalized schema or assurance that the current upstream will keep them unchanged.

`POST /player/:action` resolves a player using upstream query values `mutex`, `netid`, and/or `license`. The upstream handler supports `mutex=current`. Connection IDs can be reused; the native bridge's `sessionId` protection does not automatically extend to this generic internal adapter. Resolve the intended upstream player carefully and review the current resolver's identity semantics before destructive actions.

| Player action parameter | Basic JSON body | Upstream permission noted in handler |
|---|---|---|
| `save_note` | `note` string | Authenticated admin; handler has no additional specific permission test |
| `warn` | `reason` string | `players.warn` |
| `ban` | `duration` string, `reason` string | `players.ban` |
| `whitelist` | `status` boolean | `players.whitelist` |
| `removeIds` | `ids` string array | `players.remove_ids` |
| `message` | `message` string | `players.direct_message` |
| `kick` | `reason` string | `players.kick` |

Ban duration syntax and player-resolution details are delegated to txAdmin's current validator, not guessed here. A legacy/native `DropPlayer` action is not an alternative way to register a txAdmin ban.

| Allowlist path | Basic JSON body |
|---|---|
| `POST /whitelist/approvals/add` | `identifier` string |
| `POST /whitelist/approvals/remove` | `identifier` string |
| `POST /whitelist/requests/approve` | `reqId` string |
| `POST /whitelist/requests/deny` | `reqId` string |
| `POST /whitelist/requests/deny_all` | `newestVisible` cutoff |

These handlers test `players.whitelist`. Preapproval accepts a validated player identifier; the upstream handles registration and event emission. The bridge does not edit txAdmin's JSON database files directly.

## Upstream response semantics

HTTP 200 alone does not mean success. The adapter treats upstream `logout`, `error`, `type: error`, and `success: false` as failures and returns a bridge error. Even an application error can follow a partial database change. Writes are never automatically retried upstream. Transport timeout is reported as outcome-unknown.

Raw privileged JSON is not privacy-filtered. Do not expose `data.upstream` wholesale on a public site or log returned credentials/PII. Text results carry `interpretation: unverified_text`; do not render them as HTML or assume a login page is successful application data. The 256 KiB upstream response check occurs after the FiveM HTTP callback receives data, not as a streaming network download cap. Do not enable large database backups or logs as if this were a streaming export service.

## Upgrade audit

```sh
python3 tools/audit_upstream.py --ref master
# or compare a checked-out source tree without network access:
python3 tools/audit_upstream.py --source-root /path/to/txAdmin
```

This detects central route-registration and documented event-name additions/removals. It does **not** prove unchanged payloads, middleware internals, permissions, WebSocket behavior or runtime compatibility. Review handler diffs and repeat staging tests after an upstream upgrade before re-enabling the adapter.

## Complete pinned central-router inventory

`apiAuthMw` means the upstream API-auth middleware, including browser-session CSRF requirements. `webAuthMw` is the rendered-page auth middleware. `hostAuthMw` is the separate environment-token mechanism. `intercomAuthMw` is private monitor/control transport. `none` only appears on blocked development-only registrations.

| Route ID | Method | Upstream path | Middleware | Bridge classification |
|---|---|---|---|---|
| `adminManager_page` | GET | `/legacy/adminManager` | `webAuthMw` | experimental |
| `cfgEditor_page` | GET | `/legacy/cfgEditor` | `webAuthMw` | experimental |
| `masterActions_page` | GET | `/legacy/masterActions` | `webAuthMw` | experimental |
| `resources` | GET | `/legacy/resources` | `webAuthMw` | experimental |
| `serverLog` | GET | `/legacy/serverLog` | `webAuthMw` | experimental |
| `whitelist_page` | GET | `/legacy/allowlist` | `webAuthMw` | experimental |
| `setup_get` | GET | `/legacy/setup` | `webAuthMw` | experimental |
| `deployer_stepper` | GET | `/legacy/deployer` | `webAuthMw` | experimental |
| `auth_self` | GET | `/auth/self` | `apiAuthMw` | reference-only: authentication lifecycle |
| `auth_verifyPassword` | POST | `/auth/password` | `authLimiter` | reference-only: authentication lifecycle |
| `auth_logout` | POST | `/auth/logout` | `authLimiter` | reference-only: authentication lifecycle |
| `auth_addMasterPin` | POST | `/auth/addMaster/pin` | `authLimiter` | reference-only: authentication lifecycle |
| `auth_addMasterCallback` | POST | `/auth/addMaster/callback` | `authLimiter` | reference-only: authentication lifecycle |
| `auth_addMasterSave` | POST | `/auth/addMaster/save` | `authLimiter` | reference-only: authentication lifecycle |
| `auth_providerRedirect` | GET | `/auth/cfxre/redirect` | `authLimiter` | reference-only: authentication lifecycle |
| `auth_providerCallback` | POST | `/auth/cfxre/callback` | `authLimiter` | reference-only: authentication lifecycle |
| `auth_changePassword` | POST | `/auth/changePassword` | `apiAuthMw` | reference-only: authentication lifecycle |
| `auth_getIdentifiers` | GET | `/auth/getIdentifiers` | `apiAuthMw` | reference-only: authentication lifecycle |
| `auth_changeIdentifiers` | POST | `/auth/changeIdentifiers` | `apiAuthMw` | reference-only: authentication lifecycle |
| `adminManager_getModal` | POST | `/adminManager/getModal/:modalType` | `webAuthMw` | experimental |
| `adminManager_actions` | POST | `/adminManager/:action` | `apiAuthMw` | experimental |
| `setup_post` | POST | `/setup/:action` | `apiAuthMw` | experimental |
| `deployer_status` | GET | `/deployer/status` | `apiAuthMw` | experimental |
| `deployer_actions` | POST | `/deployer/recipe/:action` | `apiAuthMw` | experimental |
| `settings_getConfigs` | GET | `/settings/configs` | `apiAuthMw` | experimental |
| `settings_saveConfigs` | POST | `/settings/configs/:card` | `apiAuthMw` | experimental |
| `settings_getBanTemplates` | GET | `/settings/banTemplates` | `apiAuthMw` | experimental |
| `settings_saveBanTemplates` | POST | `/settings/banTemplates` | `apiAuthMw` | experimental |
| `settings_resetServerDataPath` | POST | `/settings/resetServerDataPath` | `apiAuthMw` | experimental |
| `masterActions_getBackup` | GET | `/masterActions/backupDatabase` | `webAuthMw` | experimental |
| `masterActions_actions` | POST | `/masterActions/:action` | `apiAuthMw` | experimental |
| `fxserver_controls` | POST | `/fxserver/controls` | `apiAuthMw` | experimental |
| `fxserver_commands` | POST | `/fxserver/commands` | `apiAuthMw` | experimental |
| `fxserver_downloadLog` | GET | `/fxserver/downloadLog` | `webAuthMw` | experimental |
| `fxserver_schedule` | POST | `/fxserver/schedule` | `apiAuthMw` | experimental |
| `cfgEditor_save` | POST | `/cfgEditor/save` | `apiAuthMw` | experimental |
| `intercom` | POST | `/intercom/:scope` | `intercomAuthMw` | blocked: private intercom |
| `diagnostics_getDiagnostics` | GET | `/diagnostics/getDiagnostics` | `apiAuthMw` | experimental |
| `diagnostics_sendReport` | POST | `/diagnostics/sendReport` | `apiAuthMw` | experimental |
| `advanced_runCommand` | POST | `/advanced/run` | `apiAuthMw` | experimental |
| `serverLogPartial` | GET | `/serverLog/partial` | `apiAuthMw` | experimental |
| `systemLogs` | GET | `/systemLog/:scope` | `apiAuthMw` | experimental |
| `perfChart` | GET | `/perfChartData/:thread` | `apiAuthMw` | experimental |
| `playerDrops` | GET | `/playerDropsData` | `apiAuthMw` | experimental |
| `history_stats` | GET | `/history/stats` | `apiAuthMw` | experimental |
| `history_search` | GET | `/history/search` | `apiAuthMw` | experimental |
| `history_actionModal` | GET | `/history/action` | `apiAuthMw` | experimental |
| `history_actions` | POST | `/history/:action` | `apiAuthMw` | experimental |
| `player_modal` | GET | `/player` | `apiAuthMw` | experimental |
| `player_stats` | GET | `/player/stats` | `apiAuthMw` | experimental |
| `player_search` | GET | `/player/search` | `apiAuthMw` | experimental |
| `player_checkJoin` | POST | `/player/checkJoin` | `intercomAuthMw` | blocked: private intercom |
| `player_actions` | POST | `/player/:action` | `apiAuthMw` | experimental |
| `whitelist_list` | GET | `/whitelist/:table` | `apiAuthMw` | experimental |
| `whitelist_actions` | POST | `/whitelist/:table/:action` | `apiAuthMw` | experimental |
| `host_status` | GET | `/host/status` | `hostAuthMw` | host-status |
| `dev_get` | GET | `/dev/:scope` | `none` | blocked: development-only |
| `dev_post` | POST | `/dev/:scope` | `none` | blocked: development-only |
