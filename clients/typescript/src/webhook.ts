import { TxBridgeEventSchema, type TxBridgeEvent } from "./schemas.ts";
import {
  canonicalWebhook,
  hmacHex,
  ID_PATTERN,
  isStrongSecret,
  normalizeHeaders,
  safeEqualHex,
  SIGNATURE_PATTERN,
  TIMESTAMP_PATTERN,
  type Body,
  type HeaderSource,
} from "./signing.ts";

/** Default receiver window. The bridge signs at send time, so retries always carry a fresh timestamp. */
export const WEBHOOK_TOLERANCE_SECONDS = 300;
/** The bridge caps events at 8 KiB (Config.Events.maxEventBytes); anything far larger is not from it. */
export const MAX_WEBHOOK_BYTES = 65_536;

export type WebhookRejection =
  /** Missing, repeated or malformed headers, or an unusable configured secret. */
  | "malformed"
  /** X-TxBridge-Server does not belong to this receiver. */
  | "wrong_server"
  | "expired"
  | "bad_signature"
  | "too_large"
  /** Signature valid, but the body is not a valid event envelope or contradicts the signed headers. */
  | "invalid_envelope";

export type WebhookResult = { ok: true; event: TxBridgeEvent } | { ok: false; reason: WebhookRejection };

/**
 * Verifies a TXBRIDGE-WEBHOOK1 delivery and parses its envelope. Order matters: nothing in the body is trusted
 * before the HMAC over the raw bytes matches.
 *
 * Replay protection is split: this function enforces the timestamp window; the receiver must deduplicate by
 * (serverId, event.id) – the bridge retries with the same body, and delivery is at-least-once by design.
 */
export function verifyWebhook(input: {
  secret: string;
  /** The txbridge_server_id this receiver is paired with. */
  serverId: string;
  headers: HeaderSource;
  /** Raw request body exactly as received – never a re-serialized object. */
  body: Body;
  nowMs?: number;
  toleranceSeconds?: number;
}): WebhookResult {
  const size = typeof input.body === "string" ? new TextEncoder().encode(input.body).byteLength : input.body.byteLength;
  if (size > MAX_WEBHOOK_BYTES) return { ok: false, reason: "too_large" };
  const headers = normalizeHeaders(input.headers);
  if (!headers || !isStrongSecret(input.secret)) return { ok: false, reason: "malformed" };
  const server = headers.get("x-txbridge-server") ?? "";
  const eventId = headers.get("x-txbridge-event") ?? "";
  const timestamp = headers.get("x-txbridge-timestamp") ?? "";
  const signature = headers.get("x-txbridge-signature") ?? "";
  if (!ID_PATTERN.test(server) || !/^[A-Za-z0-9_-]{1,128}$/.test(eventId) || !SIGNATURE_PATTERN.test(signature)) {
    return { ok: false, reason: "malformed" };
  }
  if (server !== input.serverId) return { ok: false, reason: "wrong_server" };
  const now = Math.floor((input.nowMs ?? Date.now()) / 1000);
  if (!TIMESTAMP_PATTERN.test(timestamp) || Math.abs(now - Number(timestamp)) > (input.toleranceSeconds ?? WEBHOOK_TOLERANCE_SECONDS)) {
    return { ok: false, reason: "expired" };
  }
  const expected = hmacHex(input.secret, canonicalWebhook({ serverId: server, eventId, timestamp, body: input.body }));
  if (!safeEqualHex(expected, signature)) return { ok: false, reason: "bad_signature" };

  let raw: unknown;
  try {
    raw = JSON.parse(typeof input.body === "string" ? input.body : new TextDecoder("utf-8", { fatal: true }).decode(input.body));
  } catch {
    return { ok: false, reason: "invalid_envelope" };
  }
  const parsed = TxBridgeEventSchema.safeParse(raw);
  if (!parsed.success || parsed.data.serverId !== server || parsed.data.id !== eventId) return { ok: false, reason: "invalid_envelope" };
  return { ok: true, event: parsed.data };
}
