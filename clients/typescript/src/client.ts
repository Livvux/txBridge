import type { z } from "zod";
import {
  ActionResultSchema,
  CapabilitiesSchema,
  EventsPageSchema,
  HealthSchema,
  ObservedStateSchema,
  PlayersSchema,
  ResourceActionResultSchema,
  ResourcesSchema,
  ResponseEnvelopeSchema,
  StatusSchema,
  type ActionResult,
  type BridgeCapabilities,
  type BridgeHealth,
  type BridgePlayer,
  type BridgeResource,
  type BridgeStatus,
  type EventsPage,
  type ObservedState,
  type ResourceActionResult,
} from "./schemas.ts";
import { ID_PATTERN, IDEMPOTENCY_PATTERN, isStrongSecret, signRequest, type HttpMethod } from "./signing.ts";

export type TxBridgeErrorKind =
  /** Network failure. For POST the outcome is unknown: retry only with the same idempotency key. */
  | "transport"
  | "timeout"
  | "too_large"
  /** Response is not a valid txBridge envelope or payload. */
  | "invalid_response"
  /** The bridge answered {ok:false}; `code` carries its error code (e.g. "forbidden", "replayed_request"). */
  | "bridge";

export class TxBridgeError extends Error {
  override readonly name = "TxBridgeError";
  readonly kind: TxBridgeErrorKind;
  readonly status: number | undefined;
  readonly code: string | undefined;
  constructor(kind: TxBridgeErrorKind, message: string, details: { status?: number; code?: string; cause?: unknown } = {}) {
    super(message, details.cause === undefined ? undefined : { cause: details.cause });
    this.kind = kind;
    this.status = details.status;
    this.code = details.code;
  }
}

export interface TxBridgeClientOptions {
  /** Public bridge base, e.g. "https://fivem.example.com/txbridge". No credentials, query or fragment. */
  baseUrl: string;
  /** txbridge_server_id – part of every signature. */
  serverId: string;
  /** Consumer slot (Config.Clients key), e.g. "modly". */
  keyId: string;
  secret: string;
  /** Inject a guarded fetch (SSRF checks, proxies, test doubles). Redirects are always refused. */
  fetch?: typeof fetch;
  timeoutMs?: number;
  maxResponseBytes?: number;
  /** Allow plain http only to 127.0.0.1 / [::1] (local tooling and tests). */
  allowLoopbackHttp?: boolean;
  now?: () => number;
}

const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MAX_RESPONSE_BYTES = 1_048_576;

/** Validates the base URL once; returns it without a trailing slash. */
export function normalizeBaseUrl(raw: string, allowLoopbackHttp = false): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new TypeError("baseUrl is not a valid URL");
  }
  const loopback = url.hostname === "127.0.0.1" || url.hostname === "[::1]";
  if (url.protocol !== "https:" && !(allowLoopbackHttp && url.protocol === "http:" && loopback)) {
    throw new TypeError("baseUrl must use https (plain http only to loopback with allowLoopbackHttp)");
  }
  if (url.username || url.password || url.search || url.hash) throw new TypeError("baseUrl must not contain credentials, query or fragment");
  return url.href.replace(/\/+$/, "");
}

async function readLimited(response: Response, limit: number): Promise<string> {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > limit) throw new TxBridgeError("too_large", `response exceeds ${limit} bytes`, { status: response.status });
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      throw new TxBridgeError("too_large", `response exceeds ${limit} bytes`, { status: response.status });
    }
    chunks.push(value);
  }
  return new TextDecoder().decode(Buffer.concat(chunks));
}

/**
 * Signed txBridge API client. Every request gets a fresh nonce (the bridge rejects reused nonces with
 * 409 replayed_request), so a GET retry is just a second call. POST actions require a caller-owned
 * idempotency key: store it before sending and reuse it for retries after transport errors.
 */
export class TxBridgeClient {
  readonly #base: string;
  readonly #options: Required<Pick<TxBridgeClientOptions, "serverId" | "keyId" | "secret" | "timeoutMs" | "maxResponseBytes">> & {
    fetch: typeof fetch;
    now: () => number;
  };

  constructor(options: TxBridgeClientOptions) {
    if (!ID_PATTERN.test(options.serverId) || !ID_PATTERN.test(options.keyId)) throw new TypeError("serverId and keyId must match [A-Za-z0-9_-]{1,64}");
    if (!isStrongSecret(options.secret)) throw new TypeError("secret must be 32–256 characters without control characters or placeholder text");
    this.#base = normalizeBaseUrl(options.baseUrl, options.allowLoopbackHttp ?? false);
    this.#options = {
      serverId: options.serverId,
      keyId: options.keyId,
      secret: options.secret,
      timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      maxResponseBytes: options.maxResponseBytes ?? DEFAULT_MAX_RESPONSE_BYTES,
      fetch: options.fetch ?? fetch,
      now: options.now ?? Date.now,
    };
  }

  health(): Promise<BridgeHealth> {
    return this.request("GET", "/v1/health", HealthSchema);
  }
  status(): Promise<BridgeStatus> {
    return this.request("GET", "/v1/status", StatusSchema);
  }
  capabilities(): Promise<BridgeCapabilities> {
    return this.request("GET", "/v1/capabilities", CapabilitiesSchema);
  }
  async players(): Promise<BridgePlayer[]> {
    return (await this.request("GET", "/v1/players", PlayersSchema)).items;
  }
  async resources(): Promise<BridgeResource[]> {
    return (await this.request("GET", "/v1/resources", ResourcesSchema)).items;
  }
  /** Events after a sequence cursor. `gap: true` means events between `after` and `oldestAvailable` are gone. */
  events(query: { after?: number; limit?: number } = {}): Promise<EventsPage> {
    const after = query.after ?? 0;
    const limit = query.limit ?? 50;
    if (!Number.isSafeInteger(after) || after < 0) throw new TypeError("after must be a nonnegative integer");
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new TypeError("limit must be 1–100");
    return this.request("GET", `/v1/events?after=${after}&limit=${limit}`, EventsPageSchema);
  }
  txadminState(): Promise<ObservedState> {
    return this.request("GET", "/v1/txadmin/state", ObservedStateSchema);
  }

  announce(message: string, idempotencyKey: string): Promise<ActionResult> {
    return this.request("POST", "/v1/actions/announce", ActionResultSchema, { message }, idempotencyKey);
  }
  messagePlayer(playerId: number, input: { sessionId: string; message: string }, idempotencyKey: string): Promise<ActionResult> {
    return this.request("POST", `/v1/players/${playerPath(playerId)}/actions/message`, ActionResultSchema, input, idempotencyKey);
  }
  kickPlayer(playerId: number, input: { sessionId: string; reason: string }, idempotencyKey: string): Promise<ActionResult> {
    return this.request("POST", `/v1/players/${playerPath(playerId)}/actions/kick`, ActionResultSchema, input, idempotencyKey);
  }
  resourceAction(resource: string, operation: "start" | "stop" | "restart", idempotencyKey: string): Promise<ResourceActionResult> {
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(resource)) throw new TypeError("resource name must match [A-Za-z0-9_-]{1,64}");
    return this.request("POST", `/v1/resources/${resource}/actions/${operation}`, ResourceActionResultSchema, {}, idempotencyKey);
  }

  /** Low-level signed call; `path` is resource-relative ("/v1/…") and must already be encoded. */
  async request<S extends z.ZodType>(method: HttpMethod, path: string, schema: S, body?: Record<string, unknown>, idempotencyKey = ""): Promise<z.output<S>> {
    if (method === "POST" && !IDEMPOTENCY_PATTERN.test(idempotencyKey)) throw new TypeError("POST requires a 16–128 character idempotency key");
    if (method === "GET" && body !== undefined) throw new TypeError("GET must not have a body");
    const raw = method === "POST" ? JSON.stringify(body ?? {}) : "";
    const headers = signRequest(this.#options.secret, {
      serverId: this.#options.serverId,
      keyId: this.#options.keyId,
      method,
      path,
      idempotencyKey: method === "POST" ? idempotencyKey : "",
      body: raw,
      timestamp: String(Math.floor(this.#options.now() / 1000)),
    });

    let response: Response;
    try {
      response = await this.#options.fetch(this.#base + path, {
        method,
        headers: { ...headers, ...(method === "POST" ? { "Content-Type": "application/json" } : {}), Accept: "application/json" },
        ...(method === "POST" ? { body: raw } : {}),
        redirect: "error",
        signal: AbortSignal.timeout(this.#options.timeoutMs),
      });
    } catch (err) {
      const timeout = err instanceof Error && (err.name === "TimeoutError" || err.name === "AbortError");
      throw new TxBridgeError(timeout ? "timeout" : "transport", timeout ? "bridge request timed out" : "bridge request failed", { cause: err });
    }

    const text = await readLimited(response, this.#options.maxResponseBytes);
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      throw new TxBridgeError("invalid_response", "bridge response is not JSON", { status: response.status });
    }
    const envelope = ResponseEnvelopeSchema.safeParse(json);
    if (!envelope.success) throw new TxBridgeError("invalid_response", "bridge response has no txBridge envelope", { status: response.status });
    if (!envelope.data.ok) {
      throw new TxBridgeError("bridge", envelope.data.error.message, { status: response.status, code: envelope.data.error.code });
    }
    const data = schema.safeParse(envelope.data.data);
    if (!data.success) throw new TxBridgeError("invalid_response", `unexpected payload for ${method} ${path.split("?")[0]}`, { status: response.status });
    return data.data;
  }
}

function playerPath(id: number): string {
  if (!Number.isSafeInteger(id) || id < 1) throw new TypeError("player id must be a positive integer");
  return String(id);
}
