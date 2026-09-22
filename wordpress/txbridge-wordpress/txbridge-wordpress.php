<?php
/**
 * Plugin Name: txBridge for WordPress
 * Description: Signed FiveM / txAdmin event receiver, private application client, and opt-in public status widget.
 * Version: 0.1.0
 * Requires at least: 6.0
 * Requires PHP: 8.1
 * License: MIT
 */
declare(strict_types=1);
if (!defined('ABSPATH')) { exit; }
define('TXBRIDGE_PLUGIN_FILE', __FILE__);
require_once __DIR__ . '/includes/class-txbridge-signing.php';
require_once __DIR__ . '/includes/class-txbridge-client.php';

final class TXBridge_WordPress {
    public static function servers(): array {
        return defined('TXBRIDGE_SERVERS') && is_array(TXBRIDGE_SERVERS) ? TXBRIDGE_SERVERS : [];
    }
    public static function table(): string { global $wpdb; return $wpdb->prefix . 'txbridge_events'; }
    public static function activate(): void {
        global $wpdb;
        require_once ABSPATH . 'wp-admin/includes/upgrade.php';
        $table = self::table(); $collate = $wpdb->get_charset_collate();
        dbDelta("CREATE TABLE $table (
            id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
            server_id varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            event_id varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            source_sequence bigint(20) unsigned NOT NULL,
            event_type varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            emitted_at bigint(20) unsigned NOT NULL,
            received_at datetime NOT NULL,
            payload_hash char(64) NOT NULL,
            payload longtext NOT NULL,
            PRIMARY KEY  (id),
            UNIQUE KEY delivery (server_id,event_id),
            KEY server_sequence (server_id,source_sequence),
            KEY status_lookup (server_id,event_type,source_sequence),
            KEY received (received_at)
        ) $collate;");
        if (!wp_next_scheduled('txbridge_cleanup')) { wp_schedule_event(time() + 3600, 'daily', 'txbridge_cleanup'); }
    }
    public static function deactivate(): void { wp_clear_scheduled_hook('txbridge_cleanup'); }
    public static function cleanup(): void {
        global $wpdb;
        $days = defined('TXBRIDGE_RETENTION_DAYS') ? max(1, min(365, (int)TXBRIDGE_RETENTION_DAYS)) : 30;
        $wpdb->query($wpdb->prepare('DELETE FROM ' . self::table() . ' WHERE received_at < %s', gmdate('Y-m-d H:i:s', time() - $days * DAY_IN_SECONDS)));
    }
    public static function registerRoutes(): void {
        register_rest_route('txbridge/v1', '/webhook', [
            'methods' => 'POST', 'permission_callback' => [self::class, 'authorizeWebhook'], 'callback' => [self::class, 'webhook'],
        ]);
        register_rest_route('txbridge/v1', '/status/(?P<server>[A-Za-z0-9_-]{1,64})', [
            'methods' => 'GET', 'permission_callback' => [self::class, 'authorizePublic'], 'callback' => [self::class, 'status'],
        ]);
        register_rest_route('txbridge/v1', '/admin/events/(?P<server>[A-Za-z0-9_-]{1,64})', [
            'methods' => 'GET', 'permission_callback' => [self::class, 'authorizeAdmin'], 'callback' => [self::class, 'events'],
        ]);
        register_rest_route('txbridge/v1', '/admin/request/(?P<server>[A-Za-z0-9_-]{1,64})', [
            'methods' => 'POST', 'permission_callback' => [self::class, 'authorizeAdmin'], 'callback' => [self::class, 'request'],
        ]);
    }
    public static function authorizeAdmin(): bool { return current_user_can('manage_options'); }
    public static function authorizePublic(WP_REST_Request $request): mixed {
        $cfg = self::servers()[(string)$request['server']] ?? null;
        if (!is_array($cfg) || ($cfg['public_status'] ?? false) !== true) { return new WP_Error('txbridge_private', 'Public status is disabled.', ['status' => 404]); }
        return true;
    }
    public static function authorizeWebhook(WP_REST_Request $request): mixed {
        $server = $request->get_header('x-txbridge-server');
        $cfg = self::servers()[$server] ?? null;
        $secret = is_array($cfg) ? (string)($cfg['webhook_secret'] ?? '') : '';
        $valid = TXBridge_Signing::verifyWebhook($server, $request->get_header('x-txbridge-event'),
            $request->get_header('x-txbridge-timestamp'), $request->get_header('x-txbridge-signature'), $request->get_body(), $secret);
        return $valid ? true : new WP_Error('txbridge_unauthorized', 'Webhook authentication failed.', ['status' => 401]);
    }
    public static function webhook(WP_REST_Request $request): mixed {
        global $wpdb;
        $raw = $request->get_body();
        try { $event = json_decode($raw, true, 32, JSON_THROW_ON_ERROR); }
        catch (JsonException $e) { return new WP_Error('txbridge_json', 'Invalid JSON.', ['status' => 400]); }
        $server = $request->get_header('x-txbridge-server');
        if (!is_array($event) || ($event['version'] ?? null) !== 1 || ($event['serverId'] ?? '') !== $server
            || !is_int($event['sequence'] ?? null) || $event['sequence'] < 1 || $event['sequence'] > 9007199254740991
            || ($event['id'] ?? '') !== $server . '-' . $event['sequence'] || $event['id'] !== $request->get_header('x-txbridge-event')
            || !is_string($event['type'] ?? null) || strlen($event['type']) > 128
            || !preg_match('/^(txadmin|fivem|bridge|custom)\.[A-Za-z][A-Za-z0-9_.-]*$/D', $event['type'])
            || !is_int($event['emittedAt'] ?? null) || $event['emittedAt'] < 1 || $event['emittedAt'] > time() + 90
            || !is_array($event['data'] ?? null)) {
            return new WP_Error('txbridge_envelope', 'Invalid event envelope.', ['status' => 400]);
        }
        $hash = hash('sha256', $raw);
        $sql = $wpdb->prepare('INSERT IGNORE INTO ' . self::table()
            . ' (server_id,event_id,source_sequence,event_type,emitted_at,received_at,payload_hash,payload) VALUES (%s,%s,%d,%s,%d,%s,%s,%s)',
            $server, $event['id'], $event['sequence'], $event['type'], $event['emittedAt'], gmdate('Y-m-d H:i:s'), $hash, $raw);
        $result = $wpdb->query($sql);
        if ($result === false) { return new WP_Error('txbridge_storage', 'Event storage failed; retry later.', ['status' => 503]); }
        if ($result === 0) {
            $storedHash = $wpdb->get_var($wpdb->prepare('SELECT payload_hash FROM ' . self::table() . ' WHERE server_id=%s AND event_id=%s', $server, $event['id']));
            if (!is_string($storedHash)) { return new WP_Error('txbridge_storage', 'Event was not stored.', ['status' => 503]); }
            if (!hash_equals($storedHash, $hash)) { return new WP_Error('txbridge_conflict', 'Event ID already has different contents.', ['status' => 409]); }
            return new WP_REST_Response(['accepted' => true, 'duplicate' => true], 200);
        }
        // Durable inbox first. Hooks are not an exactly-once transaction with this insert.
        $hookOk = true;
        try { do_action('txbridge_event', $event, $server); }
        catch (Throwable $e) { $hookOk = false; error_log('[txBridge] Event stored, but an application hook failed. Reconcile from the inbox.'); }
        return new WP_REST_Response(['accepted' => true, 'duplicate' => false, 'hookCompleted' => $hookOk], 202);
    }
    public static function snapshot(string $server): array {
        global $wpdb;
        $raw = $wpdb->get_var($wpdb->prepare('SELECT payload FROM ' . self::table()
            . " WHERE server_id=%s AND event_type='bridge.status' ORDER BY source_sequence DESC LIMIT 1", $server));
        $event = is_string($raw) ? json_decode($raw, true) : null;
        $cfg = self::servers()[$server] ?? [];
        $label = (string)($cfg['label'] ?? $server);
        $at = is_array($event) ? (int)($event['emittedAt'] ?? 0) : 0;
        $state = $at === 0 ? 'unknown' : (time() - $at <= 90 ? 'online' : 'stale');
        $data = is_array($event['data'] ?? null) ? $event['data'] : [];
        // Explicit allowlist: never expose raw payloads, IDs, names, admin events or queue contents.
        return ['serverId' => $server, 'label' => $label, 'state' => $state,
            'players' => max(0, (int)($data['players'] ?? 0)), 'maxPlayers' => max(0, (int)($data['maxPlayers'] ?? 0)),
            'observedAt' => $at ?: null, 'staleAfterSeconds' => 90];
    }
    public static function status(WP_REST_Request $request): WP_REST_Response {
        return new WP_REST_Response(self::snapshot((string)$request['server']), 200, ['Cache-Control' => 'no-store']);
    }
    public static function events(WP_REST_Request $request): mixed {
        global $wpdb;
        $server = (string)$request['server'];
        if (!isset(self::servers()[$server])) { return new WP_Error('txbridge_server', 'Unknown server.', ['status' => 404]); }
        $after = $request->get_param('after') ?? '0';
        $limit = $request->get_param('limit') ?? '50';
        if (!ctype_digit((string)$after) || !ctype_digit((string)$limit) || (int)$limit < 1 || (int)$limit > 100) {
            return new WP_Error('txbridge_query', 'Invalid cursor or limit.', ['status' => 400]);
        }
        // Receipt cursor (id), not origin sequence: delayed webhook deliveries may arrive out of order.
        $rows = $wpdb->get_results($wpdb->prepare('SELECT id,payload FROM ' . self::table()
            . ' WHERE server_id=%s AND id>%d ORDER BY id ASC LIMIT %d', $server, (int)$after, (int)$limit), ARRAY_A);
        if (!is_array($rows)) { return new WP_Error('txbridge_storage', 'Inbox query failed.', ['status' => 503]); }
        $items = []; $cursor = (int)$after;
        foreach ($rows as $row) { $cursor = (int)$row['id']; $items[] = ['receiptId' => $cursor, 'event' => json_decode($row['payload'], true)]; }
        return new WP_REST_Response(['items' => $items, 'cursor' => $cursor], 200, ['Cache-Control' => 'no-store']);
    }
    public static function request(WP_REST_Request $request): mixed {
        $input = $request->get_json_params();
        if (!is_array($input) || !is_string($input['method'] ?? null) || !is_string($input['path'] ?? null)) {
            return new WP_Error('txbridge_request', 'Supply method and relative path.', ['status' => 400]);
        }
        if (isset($input['idempotencyKey']) && !is_string($input['idempotencyKey'])) { return new WP_Error('txbridge_request', 'Invalid idempotency key.', ['status' => 400]); }
        return TXBridge_Client::request((string)$request['server'], $input['method'], $input['path'], $input['body'] ?? null, $input['idempotencyKey'] ?? '');
    }
    public static function shortcode(array|string $attrs = []): string {
        $attrs = shortcode_atts(['server' => 'main'], is_array($attrs) ? $attrs : [], 'txbridge_status');
        $server = (string)$attrs['server'];
        if ((self::servers()[$server]['public_status'] ?? false) !== true) { return ''; }
        $snapshot = self::snapshot($server);
        wp_enqueue_script('txbridge-status', plugins_url('assets/status.js', TXBRIDGE_PLUGIN_FILE), [], '0.1.0', true);
        $text = $snapshot['state'] === 'online' ? $snapshot['players'] . ' / ' . $snapshot['maxPlayers'] . ' players' : 'Status unavailable';
        return '<div class="txbridge-status" data-endpoint="' . esc_url(rest_url('txbridge/v1/status/' . rawurlencode($server))) . '">'
            . '<strong>' . esc_html($snapshot['label']) . '</strong> <span role="status">' . esc_html($text) . '</span></div>';
    }
    public static function menu(): void { add_management_page('txBridge', 'txBridge', 'manage_options', 'txbridge', [self::class, 'page']); }
    public static function page(): void {
        if (!current_user_can('manage_options')) { return; }
        echo '<div class="wrap"><h1>txBridge</h1><p>Connections are configured in wp-config.php. Secrets are not displayed or stored as plugin options.</p>';
        foreach (self::servers() as $server => $cfg) {
            $s = self::snapshot((string)$server);
            echo '<h2>' . esc_html($s['label']) . '</h2><p>' . esc_html($s['state']) . ' — '
                . esc_html((string)$s['players']) . ' / ' . esc_html((string)$s['maxPlayers']) . ' players</p>';
        }
        echo '<p>Public widget, after enabling public_status: <code>[txbridge_status server="main"]</code></p>';
        echo '<p>A stale snapshot means telemetry is unavailable; it does not prove the game server is stopped.</p></div>';
    }
}
register_activation_hook(__FILE__, [TXBridge_WordPress::class, 'activate']);
register_deactivation_hook(__FILE__, [TXBridge_WordPress::class, 'deactivate']);
add_action('rest_api_init', [TXBridge_WordPress::class, 'registerRoutes']);
add_action('txbridge_cleanup', [TXBridge_WordPress::class, 'cleanup']);
add_action('admin_menu', [TXBridge_WordPress::class, 'menu']);
add_shortcode('txbridge_status', [TXBridge_WordPress::class, 'shortcode']);
