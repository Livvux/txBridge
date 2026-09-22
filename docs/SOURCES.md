# Source review and compatibility baseline

Reviewed on **2026-09-22**. txAdmin central-router baseline: **8a9a41410000fd92a527fe11bae2b8eeeb8b10e0**. The source review distinguishes documented notification integration from version-dependent panel internals. The links below are upstream references, not services this package contacts automatically except when explicitly configured or running the audit tool.

## txAdmin primary sources

- [Repository and integration overview](https://github.com/citizenfx/txAdmin/tree/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0)
- [Documented server events](https://github.com/citizenfx/txAdmin/blob/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0/docs/events.md): event names, fields, deprecated aliases, and warning about missed offline events.
- [Central HTTP router](https://github.com/citizenfx/txAdmin/blob/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0/core/modules/WebServer/router.ts): all 58 inventoried registrations, middleware names and two development-only registrations.
- [Authentication middleware](https://github.com/citizenfx/txAdmin/blob/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0/core/modules/WebServer/middlewares/authMws.ts): host environment token, intercom separation, web/API session checks and CSRF.
- [Authentication logic](https://github.com/citizenfx/txAdmin/blob/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0/core/modules/WebServer/authLogic.ts): browser session validation, admin resolution and separate NUI authentication.
- [Route exports](https://github.com/citizenfx/txAdmin/blob/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0/core/routes/index.ts): handler mapping.
- [Host-status handler](https://github.com/citizenfx/txAdmin/blob/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0/core/routes/hostStatus.ts): returns the manager's host-status object.
- [Player action handler](https://github.com/citizenfx/txAdmin/blob/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0/core/routes/player/actions.ts): verified dynamic action names, inputs, permissions, database updates and event dispatch.
- [Allowlist action handler](https://github.com/citizenfx/txAdmin/blob/8a9a41410000fd92a527fe11bae2b8eeeb8b10e0/core/routes/whitelist/actions.ts): approvals/requests operations and emitted events.

The route inventory is derived metadata, not a distribution of upstream implementation files. Dynamic bodies for every internal handler, every development function and every frontend protocol were not independently specified or tested.

## Cfx.re primary references

- [SetHttpHandler native](https://docs.fivem.net/natives/?_0xF5C6330C=): resource HTTP request/response interface.
- [PerformHttpRequest](https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/PerformHttpRequest/): native request callback and redirect options.
- [Secure your events](https://docs.fivem.net/docs/developers/server-security/): local versus network event handling and server-side validation.

## WordPress primary references

- [Adding custom REST endpoints](https://developer.wordpress.org/rest-api/extending-the-rest-api/adding-custom-endpoints/): route registration and permission callbacks.
- [wp_remote_request](https://developer.wordpress.org/reference/functions/wp_remote_request/): server-side HTTP transport.
- [REST authentication](https://developer.wordpress.org/rest-api/using-the-rest-api/authentication/): normal WordPress authentication/nonce model.

## Cryptographic test reference

The test suite includes SHA-256 known answers and HMAC-SHA256 test cases from [RFC 4231](https://www.rfc-editor.org/rfc/rfc4231). Protocol fixtures also use the host Python standard library to cross-check exact body bytes. Passing vectors is not a substitute for an independent security review.
