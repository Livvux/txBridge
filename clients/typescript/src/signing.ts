import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

/** Wire schemes implemented by the Lua bridge (resource/txbridge/server/security.lua, transport.lua). */
export const REQUEST_SCHEME = "TXBRIDGE1";
export const WEBHOOK_SCHEME = "TXBRIDGE-WEBHOOK1";

/** Same bounds the bridge enforces; checking them locally turns silent 401s into clear errors. */
export const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
export const NONCE_PATTERN = /^[A-Za-z0-9_-]{24,128}$/;
export const IDEMPOTENCY_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
export const TIMESTAMP_PATTERN = /^\d{10}$/;
export const SIGNATURE_PATTERN = /^[0-9a-f]{64}$/;
/** Bridge request clock-skew window (Config.Http.clockSkewSeconds). */
export const REQUEST_SKEW_SECONDS = 90;

export type Body = string | Uint8Array;
export type HttpMethod = "GET" | "POST";

const bytes = (body: Body): Uint8Array => (typeof body === "string" ? new TextEncoder().encode(body) : body);

export const sha256Hex = (body: Body): string => createHash("sha256").update(bytes(body)).digest("hex");

export const hmacHex = (secret: string, message: string): string =>
  createHmac("sha256", Buffer.from(secret, "utf8")).update(message, "utf8").digest("hex");

/** Constant-time comparison of two lowercase hex digests; false for any malformed input. */
export function safeEqualHex(a: string, b: string): boolean {
  if (!SIGNATURE_PATTERN.test(a) || !SIGNATURE_PATTERN.test(b)) return false;
  return timingSafeEqual(Buffer.from(a, "hex"), Buffer.from(b, "hex"));
}

/** Mirrors B.secret(): 32–256 chars, no control characters, no unedited placeholder text. */
export function isStrongSecret(secret: string): boolean {
  const lower = secret.toLowerCase();
  // eslint-disable-next-line no-control-regex
  return secret.length >= 32 && secret.length <= 256 && !/[\u0000-\u001f\u007f]/.test(secret) && !lower.includes("change") && !lower.includes("replace");
}

/** Unix seconds as the bridge expects them (exactly 10 digits). */
export const unixTimestamp = (nowMs: number = Date.now()): string => String(Math.floor(nowMs / 1000));

/** 24 random bytes as base64url: 32 chars, inside the bridge nonce alphabet and length. */
export const newNonce = (): string => randomBytes(24).toString("base64url");

/** Caller-owned idempotency key for POST actions. Persist it before sending so a retry reuses it. */
export const newIdempotencyKey = (): string => randomBytes(18).toString("base64url");

export interface RequestSigningInput {
  serverId: string;
  keyId: string;
  method: HttpMethod;
  /** Resource-relative target including the query string, e.g. "/v1/events?after=41&limit=100". */
  path: string;
  timestamp: string;
  nonce: string;
  idempotencyKey: string;
  body: Body;
}

export const canonicalRequest = (i: RequestSigningInput): string =>
  [REQUEST_SCHEME, i.serverId, i.keyId, i.method, i.path, i.timestamp, i.nonce, i.idempotencyKey, sha256Hex(i.body)].join("\n");

export interface WebhookSigningInput {
  serverId: string;
  eventId: string;
  timestamp: string;
  body: Body;
}

export const canonicalWebhook = (i: WebhookSigningInput): string =>
  [WEBHOOK_SCHEME, i.serverId, i.eventId, i.timestamp, sha256Hex(i.body)].join("\n");

export interface SignedRequestHeaders {
  "X-TxBridge-Key": string;
  "X-TxBridge-Timestamp": string;
  "X-TxBridge-Nonce": string;
  "X-TxBridge-Signature": string;
  "Idempotency-Key"?: string;
}

export function signRequest(
  secret: string,
  input: Omit<RequestSigningInput, "timestamp" | "nonce"> & { timestamp?: string; nonce?: string },
): SignedRequestHeaders {
  const signed: RequestSigningInput = { ...input, timestamp: input.timestamp ?? unixTimestamp(), nonce: input.nonce ?? newNonce() };
  if (!ID_PATTERN.test(signed.serverId) || !ID_PATTERN.test(signed.keyId)) throw new TypeError("serverId and keyId must match [A-Za-z0-9_-]{1,64}");
  if (!TIMESTAMP_PATTERN.test(signed.timestamp)) throw new TypeError("timestamp must be 10-digit Unix seconds");
  if (!NONCE_PATTERN.test(signed.nonce)) throw new TypeError("nonce must match [A-Za-z0-9_-]{24,128}");
  if (signed.idempotencyKey !== "" && !IDEMPOTENCY_PATTERN.test(signed.idempotencyKey)) throw new TypeError("idempotencyKey must match [A-Za-z0-9_-]{16,128}");
  if (signed.method === "POST" && signed.idempotencyKey === "") throw new TypeError("POST requires an idempotency key");
  if (!signed.path.startsWith("/v1/")) throw new TypeError("path must be resource-relative and start with /v1/");
  const headers: SignedRequestHeaders = {
    "X-TxBridge-Key": signed.keyId,
    "X-TxBridge-Timestamp": signed.timestamp,
    "X-TxBridge-Nonce": signed.nonce,
    "X-TxBridge-Signature": hmacHex(secret, canonicalRequest(signed)),
  };
  if (signed.idempotencyKey !== "") headers["Idempotency-Key"] = signed.idempotencyKey;
  return headers;
}

export interface SignedWebhookHeaders {
  "X-TxBridge-Server": string;
  "X-TxBridge-Event": string;
  "X-TxBridge-Timestamp": string;
  "X-TxBridge-Signature": string;
}

/** Produces the exact headers transport.lua sends; for test doubles and alternative bridge implementations. */
export function signWebhook(secret: string, input: Omit<WebhookSigningInput, "timestamp"> & { timestamp?: string }): SignedWebhookHeaders {
  const timestamp = input.timestamp ?? unixTimestamp();
  return {
    "X-TxBridge-Server": input.serverId,
    "X-TxBridge-Event": input.eventId,
    "X-TxBridge-Timestamp": timestamp,
    "X-TxBridge-Signature": hmacHex(secret, canonicalWebhook({ ...input, timestamp })),
  };
}

export type HeaderSource = Headers | Readonly<Record<string, string | readonly string[] | undefined>>;

/** Lowercased single-valued headers; null if a security-relevant header is repeated. */
export function normalizeHeaders(source: HeaderSource): Map<string, string> | null {
  const out = new Map<string, string>();
  if (source instanceof Headers) {
    source.forEach((value, name) => out.set(name.toLowerCase(), value));
    // Headers joins repeats with ", "; a comma never occurs in a legitimate txBridge header value.
    for (const [name, value] of out) if (name.startsWith("x-txbridge-") && value.includes(",")) return null;
    return out;
  }
  for (const [name, value] of Object.entries(source)) {
    if (value === undefined) continue;
    const key = name.toLowerCase();
    if (out.has(key) || (typeof value !== "string" && value.length !== 1)) return null;
    out.set(key, typeof value === "string" ? value : value[0]!);
  }
  return out;
}

export type RequestRejection = "malformed" | "unknown_key" | "expired" | "bad_signature" | "replayed" | "idempotency_required";

/**
 * Server-side TXBRIDGE1 verification with the bridge's exact rules, for test doubles and compatible bridges.
 * `seenNonce` must atomically record the nonce and return true if it was already present.
 */
export function verifyRequest(input: {
  serverId: string;
  method: HttpMethod;
  path: string;
  headers: HeaderSource;
  body: Body;
  secretFor: (keyId: string) => string | undefined;
  nowMs?: number;
  skewSeconds?: number;
  seenNonce?: (keyId: string, nonce: string) => boolean;
}): { ok: true; keyId: string; idempotencyKey: string } | { ok: false; reason: RequestRejection } {
  const headers = normalizeHeaders(input.headers);
  if (!headers) return { ok: false, reason: "malformed" };
  const keyId = headers.get("x-txbridge-key") ?? "";
  const timestamp = headers.get("x-txbridge-timestamp") ?? "";
  const nonce = headers.get("x-txbridge-nonce") ?? "";
  const signature = headers.get("x-txbridge-signature") ?? "";
  const idempotencyKey = headers.get("idempotency-key") ?? "";
  if (!ID_PATTERN.test(keyId)) return { ok: false, reason: "malformed" };
  const secret = input.secretFor(keyId);
  if (secret === undefined || !isStrongSecret(secret)) return { ok: false, reason: "unknown_key" };
  const now = Math.floor((input.nowMs ?? Date.now()) / 1000);
  if (!TIMESTAMP_PATTERN.test(timestamp) || Math.abs(now - Number(timestamp)) > (input.skewSeconds ?? REQUEST_SKEW_SECONDS)) {
    return { ok: false, reason: "expired" };
  }
  if (!NONCE_PATTERN.test(nonce) || !SIGNATURE_PATTERN.test(signature)) return { ok: false, reason: "malformed" };
  if (idempotencyKey !== "" && !IDEMPOTENCY_PATTERN.test(idempotencyKey)) return { ok: false, reason: "malformed" };
  const expected = hmacHex(secret, canonicalRequest({ ...input, keyId, timestamp, nonce, idempotencyKey }));
  if (!safeEqualHex(expected, signature)) return { ok: false, reason: "bad_signature" };
  if (input.seenNonce?.(keyId, nonce)) return { ok: false, reason: "replayed" };
  if (input.method === "POST" && idempotencyKey === "") return { ok: false, reason: "idempotency_required" };
  return { ok: true, keyId, idempotencyKey };
}
