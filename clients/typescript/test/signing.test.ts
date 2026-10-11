import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  canonicalRequest,
  canonicalWebhook,
  hmacHex,
  isStrongSecret,
  newIdempotencyKey,
  newNonce,
  NONCE_PATTERN,
  IDEMPOTENCY_PATTERN,
  safeEqualHex,
  sha256Hex,
  signRequest,
  verifyRequest,
} from "../src/index.ts";

interface RequestVector {
  name: string;
  secret: string;
  serverId: string;
  keyId: string;
  method: "GET" | "POST";
  path: string;
  timestamp: string;
  nonce: string;
  idempotencyKey: string;
  body: string;
  bodySha256: string;
  canonical: string;
  signature: string;
}
interface WebhookVector {
  name: string;
  secret: string;
  serverId: string;
  eventId: string;
  timestamp: string;
  body: string;
  bodySha256: string;
  canonical: string;
  signature: string;
}
const vectors = JSON.parse(readFileSync(new URL("../../../tests/signing-vectors.json", import.meta.url), "utf8")) as {
  requests: RequestVector[];
  webhooks: WebhookVector[];
};

test("request signatures match every Lua-generated vector", () => {
  assert.ok(vectors.requests.length >= 4);
  for (const v of vectors.requests) {
    assert.equal(sha256Hex(v.body), v.bodySha256, v.name);
    assert.equal(canonicalRequest(v), v.canonical, v.name);
    assert.equal(hmacHex(v.secret, v.canonical), v.signature, v.name);
    const headers = signRequest(v.secret, v);
    assert.equal(headers["X-TxBridge-Signature"], v.signature, v.name);
    assert.equal(headers["Idempotency-Key"], v.idempotencyKey === "" ? undefined : v.idempotencyKey);
  }
});

test("webhook signatures match every Lua-generated vector", () => {
  assert.ok(vectors.webhooks.length >= 3);
  for (const v of vectors.webhooks) {
    assert.equal(canonicalWebhook(v), v.canonical, v.name);
    assert.equal(hmacHex(v.secret, v.canonical), v.signature, v.name);
  }
});

test("byte bodies hash identically to their UTF-8 string form", () => {
  const unicode = vectors.requests.find((v) => /[^\p{ASCII}]/u.test(v.body))!;
  assert.equal(sha256Hex(new TextEncoder().encode(unicode.body)), unicode.bodySha256);
});

test("legacy single protocol fixture still verifies", () => {
  const v = JSON.parse(readFileSync(new URL("../../../tests/protocol-vectors.json", import.meta.url), "utf8")) as Record<string, string>;
  const signed = signRequest(v.secret!, {
    serverId: v.server!,
    keyId: v.key!,
    method: "POST",
    path: v.path!,
    timestamp: v.timestamp!,
    nonce: v.nonce!,
    idempotencyKey: v.idempotency!,
    body: v.body!,
  });
  assert.equal(signed["X-TxBridge-Signature"], v.requestSignature);
  assert.equal(hmacHex(v.webhookSecret!, canonicalWebhook({ serverId: v.server!, eventId: v.eventId!, timestamp: v.timestamp!, body: v.eventBody! })), v.webhookSignature);
});

test("generated nonces and idempotency keys satisfy the bridge alphabet", () => {
  const nonces = new Set(Array.from({ length: 50 }, newNonce));
  assert.equal(nonces.size, 50);
  for (const n of nonces) assert.match(n, NONCE_PATTERN);
  assert.match(newIdempotencyKey(), IDEMPOTENCY_PATTERN);
});

test("signRequest refuses inputs the bridge would reject", () => {
  const base = { serverId: "main", keyId: "modly", method: "GET" as const, path: "/v1/status", idempotencyKey: "", body: "" };
  const secret = "s".repeat(64);
  assert.throws(() => signRequest(secret, { ...base, serverId: "bad id" }));
  assert.throws(() => signRequest(secret, { ...base, path: "/status" }));
  assert.throws(() => signRequest(secret, { ...base, method: "POST" }), /idempotency/);
  assert.throws(() => signRequest(secret, { ...base, idempotencyKey: "short" }));
  assert.throws(() => signRequest(secret, { ...base, nonce: "too-short" }));
});

test("secret strength mirrors the bridge rules", () => {
  assert.ok(isStrongSecret("a".repeat(32)));
  assert.ok(!isStrongSecret("a".repeat(31)));
  assert.ok(!isStrongSecret("a".repeat(257)));
  assert.ok(!isStrongSecret(`${"a".repeat(40)}CHANGE_ME`));
  assert.ok(!isStrongSecret(`${"a".repeat(40)}\n`));
});

test("safeEqualHex rejects malformed and unequal digests", () => {
  const a = sha256Hex("a");
  assert.ok(safeEqualHex(a, a));
  assert.ok(!safeEqualHex(a, sha256Hex("b")));
  assert.ok(!safeEqualHex(a, a.toUpperCase()));
  assert.ok(!safeEqualHex(a, a.slice(2)));
});

test("verifyRequest accepts a signed request once and enforces the bridge rules", () => {
  const secret = "k".repeat(64);
  const seen = new Set<string>();
  const nowMs = 1_700_000_000_000;
  const headers = signRequest(secret, { serverId: "main", keyId: "modly", method: "GET", path: "/v1/status", idempotencyKey: "", body: "", timestamp: "1700000000" });
  const verify = (h: Record<string, string>, overrides: Partial<Parameters<typeof verifyRequest>[0]> = {}) =>
    verifyRequest({
      serverId: "main",
      method: "GET",
      path: "/v1/status",
      headers: h,
      body: "",
      secretFor: (k) => (k === "modly" ? secret : undefined),
      nowMs,
      seenNonce: (k, n) => seen.has(`${k}:${n}`) || (seen.add(`${k}:${n}`), false),
      ...overrides,
    });
  assert.deepEqual(verify({ ...headers }), { ok: true, keyId: "modly", idempotencyKey: "" });
  assert.deepEqual(verify({ ...headers }), { ok: false, reason: "replayed" });
  assert.deepEqual(verify({ ...headers }, { path: "/v1/players" }), { ok: false, reason: "bad_signature" });
  assert.deepEqual(verify({ ...headers }, { nowMs: nowMs + 91_000 }), { ok: false, reason: "expired" });
  assert.deepEqual(verify({ ...headers, "X-TxBridge-Key": "unknown" }), { ok: false, reason: "unknown_key" });
  assert.deepEqual(verify({ ...headers, "x-txbridge-key": "modly" }), { ok: false, reason: "malformed" });
});
