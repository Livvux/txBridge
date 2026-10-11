import { z } from "zod";

/**
 * Response and event shapes of txBridge 0.1.x. Unknown fields are stripped, not rejected, so newer bridges
 * stay readable; missing or mistyped fields fail validation instead of reaching application code.
 */

const int = z.number().int();
const nonNegative = int.min(0);
/** Lua tables without keys are encoded by FiveM as [] – accept both for object-or-empty payloads. */
const emptyAsObject = z.array(z.never()).length(0).transform((): Record<string, unknown> => ({}));

export const EVENT_TYPE_PATTERN = /^(txadmin|fivem|bridge|custom)\.[A-Za-z][A-Za-z0-9_.-]*$/;

export const TxBridgeEventSchema = z
  .object({
    version: z.literal(1),
    id: z.string().regex(/^[A-Za-z0-9_-]{1,64}-\d{1,16}$/),
    sequence: int.min(1).max(Number.MAX_SAFE_INTEGER),
    serverId: z.string().regex(/^[A-Za-z0-9_-]{1,64}$/),
    type: z.string().max(128).regex(EVENT_TYPE_PATTERN),
    origin: z.string().min(1).max(160),
    /** Bis 9999-12-31: größere Werte ergäben ein ungültiges Date beim Empfänger */
    emittedAt: int.min(1).max(253_402_300_799),
    /** Object for almost every event; an array for txadmin.adminsUpdated. */
    data: z.union([z.record(z.string(), z.unknown()), z.array(z.unknown())]),
  })
  .refine((e) => e.id === `${e.serverId}-${e.sequence}`, { message: "id must equal <serverId>-<sequence>", path: ["id"] });
export type TxBridgeEvent = z.output<typeof TxBridgeEventSchema>;

export const StatusSchema = z.object({
  serverId: z.string(),
  version: z.string(),
  resource: z.string(),
  hostname: z.string(),
  players: nonNegative,
  maxPlayers: nonNegative,
  bridgeStartedAt: int,
  bridgeUptimeSeconds: nonNegative,
  fxserverVersion: z.string(),
  monitorState: z.string(),
  observedAt: int,
  processState: z.string(),
  eventSequence: nonNegative,
  queue: z.object({ pending: nonNegative, deadLetters: nonNegative, dropped: nonNegative }),
  fault: z.union([z.string(), z.literal(false)]),
  metrics: z.union([z.record(z.string(), z.number()), emptyAsObject]),
});
export type BridgeStatus = z.output<typeof StatusSchema>;

export const HealthSchema = z.object({ healthy: z.boolean(), serverId: z.string() });
export type BridgeHealth = z.output<typeof HealthSchema>;

export const CapabilitiesSchema = z.object({
  version: z.string(),
  serverId: z.string(),
  events: z.array(z.string()),
  signing: z.string(),
  webhookSigning: z.string(),
  guarantees: z.record(z.string(), z.boolean()),
});
export type BridgeCapabilities = z.output<typeof CapabilitiesSchema>;

/** GetPlayerPing kann während des Verbindens negative Werte liefern – nicht die ganze Liste daran scheitern lassen. */
export const PlayerSchema = z.object({ id: int.min(1), sessionId: z.string(), name: z.string(), ping: int });
export const PlayersSchema = z.object({ items: z.array(PlayerSchema) });
export type BridgePlayer = z.output<typeof PlayerSchema>;

export const ResourceSchema = z.object({ name: z.string().min(1), state: z.string() });
export const ResourcesSchema = z.object({ items: z.array(ResourceSchema) });
export type BridgeResource = z.output<typeof ResourceSchema>;

export const EventsPageSchema = z.object({
  items: z.array(TxBridgeEventSchema),
  cursor: nonNegative,
  latest: nonNegative,
  oldestAvailable: nonNegative,
  gap: z.boolean(),
  authoritative: z.boolean(),
});
export type EventsPage = z.output<typeof EventsPageSchema>;

export const ObservedStateSchema = z.object({
  observed: z.object({ complete: z.boolean(), since: int }).loose(),
  authoritative: z.boolean(),
});
export type ObservedState = z.output<typeof ObservedStateSchema>;

export const ActionResultSchema = z.object({}).loose();
export type ActionResult = z.output<typeof ActionResultSchema>;

export const ResourceActionResultSchema = z.object({
  resource: z.string(),
  operation: z.enum(["start", "stop", "restart"]),
  before: z.string(),
  after: z.string(),
  success: z.boolean(),
});
export type ResourceActionResult = z.output<typeof ResourceActionResultSchema>;

export const ErrorBodySchema = z.object({ code: z.string(), message: z.string() }).loose();

/** Every bridge response is {ok:true,data} or {ok:false,error:{code,message}}. */
export const ResponseEnvelopeSchema = z.discriminatedUnion("ok", [
  z.object({ ok: z.literal(true), data: z.unknown() }),
  z.object({ ok: z.literal(false), error: ErrorBodySchema }),
]);
