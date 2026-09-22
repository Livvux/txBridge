-- In another SERVER resource; first add that resource name to Config.Events.allowedPublishers.
-- Publishers are trusted code. Do not send passwords, payment data, or raw personal identifiers.
local eventId, err = exports.txbridge:PublishEvent('queue.updated', {
    waiting = 12,
    estimatedWaitSeconds = 90,
})
if not eventId then print(('txBridge publish failed: %s'):format(err or 'unknown')) end
-- The receiving application sees type = custom.queue.updated, not a forged txAdmin event.
