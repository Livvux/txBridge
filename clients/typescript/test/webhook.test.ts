import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { signWebhook, verifyWebhook, MAX_WEBHOOK_BYTES } from "../src/index.ts";

const vectors = JSON.parse(readFileSync(new URL("../../../tests/signing-vectors.json", import.meta.url), "utf8")) as {
  webhooks: Array<{ name: string; secret: string; serverId: string; eventId: string; timestamp: string; body: string; signature: string }>;
};

const secret = "w".repeat(64);
const event = (overrides: Record<string, unknown> = {}) => ({
  version: 1,
  id: "main-42",
  sequence: 42,
  serverId: "main",
  type: "txadmin.announcement",
  origin: "txadmin_event",
  emittedAt: 1_700_000_000,
  data: { author: "[redacted]", message: "Restart in 5 min" },
  ...overrides,
});
const deliver = (body: string, opts: { serverId?: string; eventId?: string; timestamp?: string } = {}) => ({
  ...signWebhook(secret, { serverId: opts.serverId ?? "main", eventId: opts.eventId ?? "main-42", body, timestamp: opts.timestamp ?? "1700000000" }),
});
const NOW = 1_700_000_100_000;

test("every Lua-generated webhook vector verifies and parses", () => {
  for (const v of vectors.webhooks) {
    const headers = { "X-TxBridge-Server": v.serverId, "X-TxBridge-Event": v.eventId, "X-TxBridge-Timestamp": v.timestamp, "X-TxBridge-Signature": v.signature };
    const result = verifyWebhook({ secret: v.secret, serverId: v.serverId, headers, body: v.body, nowMs: Number(v.timestamp) * 1000 });
    assert.ok(result.ok, `${v.name}: ${result.ok ? "" : result.reason}`);
    assert.equal(result.event.id, v.eventId);
  }
});

test("empty Lua object arrives as [] and stays a valid envelope", () => {
  const v = vectors.webhooks.find((w) => w.body.includes('"data":[]'))!;
  const headers = { "X-TxBridge-Server": v.serverId, "X-TxBridge-Event": v.eventId, "X-TxBridge-Timestamp": v.timestamp, "X-TxBridge-Signature": v.signature };
  const result = verifyWebhook({ secret: v.secret, serverId: v.serverId, headers, body: v.body, nowMs: Number(v.timestamp) * 1000 });
  assert.ok(result.ok);
  assert.deepEqual(result.event.data, []);
});

test("valid delivery from Headers and from raw bytes", () => {
  const body = JSON.stringify(event());
  const fromHeaders = verifyWebhook({ secret, serverId: "main", headers: new Headers(deliver(body)), body, nowMs: NOW });
  assert.ok(fromHeaders.ok);
  const fromBytes = verifyWebhook({ secret, serverId: "main", headers: deliver(body), body: new TextEncoder().encode(body), nowMs: NOW });
  assert.ok(fromBytes.ok);
});

test("rejections are specific and never trust the body before the HMAC", () => {
  const body = JSON.stringify(event());
  const reject = (input: Partial<Parameters<typeof verifyWebhook>[0]>) =>
    verifyWebhook({ secret, serverId: "main", headers: deliver(body), body, nowMs: NOW, ...input });
  assert.deepEqual(reject({ body: `${body} ` }), { ok: false, reason: "bad_signature" });
  assert.deepEqual(reject({ secret: "x".repeat(64) }), { ok: false, reason: "bad_signature" });
  assert.deepEqual(reject({ serverId: "other" }), { ok: false, reason: "wrong_server" });
  assert.deepEqual(reject({ nowMs: NOW + 301_000 }), { ok: false, reason: "expired" });
  assert.deepEqual(reject({ secret: "short" }), { ok: false, reason: "malformed" });
  assert.deepEqual(reject({ headers: { ...deliver(body), "X-TxBridge-Signature": "nothex" } }), { ok: false, reason: "malformed" });
  assert.deepEqual(reject({ headers: { ...deliver(body), "x-txbridge-server": "main" } }), { ok: false, reason: "malformed" });
  assert.deepEqual(reject({ body: "x".repeat(MAX_WEBHOOK_BYTES + 1) }), { ok: false, reason: "too_large" });
});

test("signed but contradictory envelopes are rejected", () => {
  const cases = [
    { body: JSON.stringify(event({ id: "main-43" })), eventId: "main-43" },
    { body: JSON.stringify(event({ serverId: "other", id: "other-42" })) },
    { body: JSON.stringify(event({ version: 2 })) },
    { body: JSON.stringify(event({ sequence: 42.5 })) },
    { body: JSON.stringify(event({ type: "evil.type" })) },
    { body: JSON.stringify(event({ emittedAt: 9_000_000_000_000 })) },
    { body: "not json" },
  ];
  for (const c of cases) {
    const result = verifyWebhook({ secret, serverId: "main", headers: deliver(c.body, { eventId: c.eventId ?? "main-42" }), body: c.body, nowMs: NOW });
    assert.deepEqual(result, { ok: false, reason: "invalid_envelope" }, c.body);
  }
});
