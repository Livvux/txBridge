<?php
declare(strict_types=1);
final class TXBridge_Client {
    /** Server-side only. Never expose secret, headers or txAdmin cookies to JavaScript. */
    public static function request(string $server, string $method, string $path, mixed $data = null, string $idem = ''): mixed {
        $configs = defined('TXBRIDGE_SERVERS') ? TXBRIDGE_SERVERS : [];
        $config = is_array($configs) ? ($configs[$server] ?? null) : null;
        if (!is_array($config)) { return new WP_Error('txbridge_config', 'Server not configured.', ['status' => 503]); }
        $base = rtrim((string)($config['url'] ?? ''), '/');
        $parts = wp_parse_url($base);
        if (!$parts || ($parts['scheme'] ?? '') !== 'https' || empty($parts['host']) || isset($parts['user']) || isset($parts['pass']) || isset($parts['query']) || isset($parts['fragment'])) {
            return new WP_Error('txbridge_config', 'Configure an HTTPS bridge base URL.', ['status' => 503]);
        }
        $method = strtoupper($method);
        $route = explode('?', $path, 2)[0];
        if (!in_array($method, ['GET', 'POST'], true) || !preg_match('#^/v1/[A-Za-z0-9_/-]+(?:\?[A-Za-z0-9_%~.=+&-]+)?$#D', $path) || strlen($path) > 4096 || str_contains($route, '//')) {
            return new WP_Error('txbridge_request', 'Invalid bridge method or relative path.', ['status' => 400]);
        }
        if ($route === '/v1/txadmin/request' && !(defined('TXBRIDGE_ALLOW_INTERNAL_PROXY') && TXBRIDGE_ALLOW_INTERNAL_PROXY)) {
            return new WP_Error('txbridge_disabled', 'Internal txAdmin proxy is disabled in WordPress.', ['status' => 403]);
        }
        if ($method === 'GET' && $data !== null) { return new WP_Error('txbridge_request', 'GET body not allowed.', ['status' => 400]); }
        if ($method === 'POST' && !preg_match('/^[A-Za-z0-9_-]{16,128}$/D', $idem)) {
            return new WP_Error('txbridge_request', 'POST requires a caller-supplied idempotency key.', ['status' => 400]);
        }
        $key = (string)($config['key_id'] ?? '');
        $secret = (string)($config['secret'] ?? '');
        if (!preg_match('/^[A-Za-z0-9_-]{1,64}$/D', $key) || strlen($secret) < 32 || strlen($secret) > 256) {
            return new WP_Error('txbridge_config', 'Configure a bridge key ID and secret.', ['status' => 503]);
        }
        $body = $method === 'GET' ? '' : wp_json_encode($data === [] || $data === null ? (object)[] : $data);
        if (!is_string($body) || strlen($body) > 32768) { return new WP_Error('txbridge_request', 'Body invalid or too large.', ['status' => 400]); }
        $response = wp_remote_request($base . $path, [
            'method' => $method,
            'headers' => TXBridge_Signing::headers($server, $key, $secret, $method, $path, $body, $idem),
            'body' => $body, 'timeout' => 15, 'redirection' => 0, 'sslverify' => true,
            'limit_response_size' => 524288,
        ]);
        if (is_wp_error($response)) { return new WP_Error('txbridge_transport', 'Bridge transport failed. Reconcile writes before retrying.', ['status' => 502]); }
        $status = wp_remote_retrieve_response_code($response);
        $decoded = json_decode(wp_remote_retrieve_body($response), true);
        if (!is_array($decoded) || !isset($decoded['ok'])) { return new WP_Error('txbridge_response', 'Invalid bridge response.', ['status' => 502]); }
        return new WP_REST_Response($decoded, $status);
    }
}
