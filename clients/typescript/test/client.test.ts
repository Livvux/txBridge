import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, test } from "node:test";
import { z } from "zod";
import { normalizeBaseUrl, PlayersSchema, TxBridgeClient, TxBridgeError, verifyRequest, type HttpMethod } from "../src/index.ts";

const StatusAny = z.unknown();

const SECRET = "c".repeat(64);
const seen = new Set<string>();
const received: Array<{ method: string; path: string; body: string; idempotencyKey: string }> = [];
let override: ((req: IncomingMessage, res: ServerResponse, body: string) => boolean) | undefined;

const status = {
  serverId: "main", version: "0.1.1", resource: "txbridge", hostname: "Test RP", players: 2, maxPlayers: 48,
  bridgeStartedAt: 1_700_000_000, bridgeUptimeSeconds: 60, fxserverVersion: "FXServer-master v1.0.0.12345 linux",
  monitorState: "started", observedAt: 1_700_000_060, processState: "running", eventSequence: 3,
  queue: { pending: 0, deadLetters: 0, dropped: 0 }, fault: false, metrics: { delivered: 3, failed: 0 },
};
const event = (sequence: number) => ({
  version: 1, id: `main-${sequence}`, sequence, serverId: "main", type: "bridge.status", origin: "bridge", emittedAt: 1_700_000_000 + sequence, data: { players: 2 },
});

const server = createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on("data", (c: Buffer) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("utf8");
    if (override?.(req, res, body)) return;
    // The resource sees the path relative to /txbridge, exactly like SetHttpHandler.
    const path = (req.url ?? "").replace(/^\/txbridge/, "");
    const auth = verifyRequest({
      serverId: "main",
      method: req.method as HttpMethod,
      path,
      headers: req.headers as Record<string, string>,
      body,
      secretFor: (key) => (key === "modly" ? SECRET : undefined),
      seenNonce: (key, nonce) => seen.has(`${key}:${nonce}`) || (seen.add(`${key}:${nonce}`), false),
    });
    const send = (code: number, payload: unknown) => {
      res.writeHead(code, { "content-type": "application/json" });
      res.end(JSON.stringify(payload));
    };
    if (!auth.ok) return send(401, { ok: false, error: { code: auth.reason, message: "Authentication failed." } });
    received.push({ method: req.method!, path, body, idempotencyKey: auth.idempotencyKey });
    if (path === "/v1/status") return send(200, { ok: true, data: status });
    if (path === "/v1/health") return send(200, { ok: true, data: { healthy: true, serverId: "main" } });
    if (path === "/v1/capabilities") {
      return send(200, { ok: true, data: { version: "0.1.1", serverId: "main", events: ["txAdmin:events:announcement"], signing: "TXBRIDGE1", webhookSigning: "TXBRIDGE-WEBHOOK1", guarantees: { exactlyOnce: false } } });
    }
    if (path === "/v1/txadmin/state") return send(200, { ok: true, data: { observed: { complete: false, since: 1_700_000_000, admins: {} }, authoritative: false } });
    if (/^\/v1\/players\/\d+\/actions\/(kick|message)$/.test(path)) return send(200, { ok: true, data: { requested: true, txAdminAction: false } });
    if (path === "/v1/resources/txb_dummy/actions/restart") {
      return send(200, { ok: true, data: { resource: "txb_dummy", operation: "restart", before: "started", after: "started", success: true } });
    }
    if (path === "/v1/players") return send(200, { ok: true, data: { items: [{ id: 1, sessionId: "main-1-1", name: "[redacted]", ping: 40 }] } });
    if (path === "/v1/resources") return send(200, { ok: true, data: { items: [{ name: "chat", state: "started" }, { name: "qb-garages", state: "stopped" }] } });
    if (path.startsWith("/v1/events?")) return send(200, { ok: true, data: { items: [event(2), event(3)], cursor: 3, latest: 3, oldestAvailable: 1, gap: false, authoritative: false } });
    if (path === "/v1/actions/announce") return send(200, { ok: true, data: { sent: true, via: "fivem_chat", txAdminAction: false } });
    if (path === "/v1/audit") return send(403, { ok: false, error: { code: "forbidden", message: "Required scope: audit:read" } });
    return send(404, { ok: false, error: { code: "not_found", message: "Endpoint not found." } });
  });
});
let client: TxBridgeClient;
let base: string;

before(async () => {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/txbridge`;
  client = new TxBridgeClient({ baseUrl: base, serverId: "main", keyId: "modly", secret: SECRET, allowLoopbackHttp: true });
});
after(() => new Promise<void>((resolve) => server.close(() => resolve())));

test("read endpoints are signed, validated and typed", async () => {
  assert.equal((await client.status()).players, 2);
  assert.deepEqual(await client.players(), [{ id: 1, sessionId: "main-1-1", name: "[redacted]", ping: 40 }]);
  assert.equal((await client.resources()).length, 2);
  const page = await client.events({ after: 1, limit: 100 });
  assert.deepEqual(page.items.map((e) => e.sequence), [2, 3]);
  assert.ok(received.some((r) => r.path === "/v1/events?after=1&limit=100"), "query string must be part of the signed path");
});

test("metadata endpoints and native actions are typed", async () => {
  assert.deepEqual(await client.health(), { healthy: true, serverId: "main" });
  assert.equal((await client.capabilities()).webhookSigning, "TXBRIDGE-WEBHOOK1");
  assert.equal((await client.txadminState()).authoritative, false);
  await client.kickPlayer(1, { sessionId: "main-1-1", reason: "Test" }, "kick_key_0000000001");
  await client.messagePlayer(1, { sessionId: "main-1-1", message: "Hi" }, "message_key_00000001");
  assert.equal((await client.resourceAction("txb_dummy", "restart", "restart_key_00000001")).after, "started");
  assert.deepEqual(received.slice(-3).map((r) => r.path), ["/v1/players/1/actions/kick", "/v1/players/1/actions/message", "/v1/resources/txb_dummy/actions/restart"]);
  assert.throws(() => client.kickPlayer(0, { sessionId: "x", reason: "x" }, "kick_key_0000000002"), TypeError);
  assert.throws(() => client.resourceAction("../evil", "stop", "restart_key_00000002"), TypeError);
  assert.throws(() => client.events({ limit: 101 }), TypeError);
  await assert.rejects(client.request("GET", "/v1/status", StatusAny, {}), TypeError);
});

test("every request uses a fresh nonce, so repeated GETs are not replays", async () => {
  await client.status();
  await client.status();
});

test("POST carries the caller's idempotency key and a JSON body", async () => {
  await client.announce("Grüße 🚀", "announce_key_000000001");
  const last = received.at(-1)!;
  assert.equal(last.idempotencyKey, "announce_key_000000001");
  assert.deepEqual(JSON.parse(last.body), { message: "Grüße 🚀" });
  await assert.rejects(client.announce("x", "short"), TypeError);
});

test("bridge errors surface status and code", async () => {
  await assert.rejects(client.request("GET", "/v1/audit", StatusAny), (err: unknown) => {
    assert.ok(err instanceof TxBridgeError);
    assert.equal(err.kind, "bridge");
    assert.equal(err.status, 403);
    assert.equal(err.code, "forbidden");
    return true;
  });
});

test("a wrong secret is rejected by the bridge-side verifier", async () => {
  const wrong = new TxBridgeClient({ baseUrl: base, serverId: "main", keyId: "modly", secret: "d".repeat(64), allowLoopbackHttp: true });
  await assert.rejects(wrong.status(), (err: unknown) => err instanceof TxBridgeError && err.code === "bad_signature");
});

test("payload drift, non-JSON, oversize and redirects are refused", async () => {
  const respond = (code: number, body: string, headers: Record<string, string> = {}) => {
    override = (_req, res) => {
      res.writeHead(code, { "content-type": "application/json", ...headers });
      res.end(body);
      return true;
    };
  };
  try {
    respond(200, JSON.stringify({ ok: true, data: { ...status, players: "two" } }));
    await assert.rejects(client.status(), (e: unknown) => e instanceof TxBridgeError && e.kind === "invalid_response");
    respond(200, "<html>login</html>");
    await assert.rejects(client.status(), (e: unknown) => e instanceof TxBridgeError && e.kind === "invalid_response");
    respond(200, JSON.stringify({ ok: true, data: "x".repeat(2_000_000) }));
    await assert.rejects(client.status(), (e: unknown) => e instanceof TxBridgeError && e.kind === "too_large");
    respond(302, "", { location: "https://evil.example/" });
    await assert.rejects(client.status(), (e: unknown) => e instanceof TxBridgeError && e.kind === "transport");
  } finally {
    override = undefined;
  }
});

test("timeouts are reported as such", async () => {
  override = () => true; // never answer
  try {
    const slow = new TxBridgeClient({ baseUrl: base, serverId: "main", keyId: "modly", secret: SECRET, allowLoopbackHttp: true, timeoutMs: 50 });
    await assert.rejects(slow.status(), (e: unknown) => e instanceof TxBridgeError && e.kind === "timeout");
  } finally {
    override = undefined;
  }
});

test("a player that is still connecting (negative ping) does not invalidate the list", () => {
  assert.equal(PlayersSchema.parse({ items: [{ id: 3, sessionId: "main-1-3", name: "[redacted]", ping: -1 }] }).items[0]!.ping, -1);
});

test("base URL rules", () => {
  assert.equal(normalizeBaseUrl("https://fivem.example.com/txbridge/"), "https://fivem.example.com/txbridge");
  assert.throws(() => normalizeBaseUrl("http://fivem.example.com/txbridge"));
  assert.throws(() => normalizeBaseUrl("http://10.0.0.5/txbridge", true));
  assert.throws(() => normalizeBaseUrl("https://user:pw@fivem.example.com/txbridge"));
  assert.throws(() => normalizeBaseUrl("https://fivem.example.com/txbridge?x=1"));
  assert.equal(normalizeBaseUrl("http://[::1]:30120/txbridge", true), "http://[::1]:30120/txbridge");
  assert.throws(() => new TxBridgeClient({ baseUrl: base, serverId: "main", keyId: "modly", secret: "weak", allowLoopbackHttp: true }));
});
