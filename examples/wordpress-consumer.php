<?php
/** Place in your own plugin after activating txBridge. This example performs no moderation. */
if (!defined('ABSPATH')) { exit; }
add_action('txbridge_event', static function (array $event, string $server): void {
    if ($event['type'] !== 'txadmin.scheduledRestart') { return; }
    // Event delivery can be late or out of order. Compare source sequence before replacing state.
    $key = 'my_txbridge_restart_' . sanitize_key($server);
    $current = get_option($key, ['sequence' => 0]);
    if (($current['sequence'] ?? 0) >= $event['sequence']) { return; }
    // This simple UI example is not a transaction; a billing/entitlement consumer needs its own
    // durable work queue, unique-event constraint, and recovery from the txBridge inbox.
    update_option($key, [
        'sequence' => $event['sequence'],
        'observedAt' => $event['emittedAt'],
        'secondsRemaining' => (int)($event['data']['secondsRemaining'] ?? 0),
    ], false);
}, 10, 2);

// Call server-side from a capability-checked handler, not on every public page load:
function my_project_get_fivem_status(): mixed {
    if (!current_user_can('manage_options')) {
        return new WP_Error('forbidden', 'Administrator permission required.', ['status' => 403]);
    }
    return TXBridge_Client::request('main', 'GET', '/v1/status');
}
