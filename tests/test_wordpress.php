<?php
declare(strict_types=1);
// WordPress and DB doubles; this does NOT replace a live WordPress/MySQL acceptance test.
define('ABSPATH', __DIR__ . '/fake-wp/');
define('DAY_IN_SECONDS', 86400);
define('ARRAY_A', 'ARRAY_A');
define('TXBRIDGE_SERVERS', [
    'main' => ['url' => 'https://bridge.example.test/txbridge', 'key_id' => 'wordpress', 'secret' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'webhook_secret' => 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', 'public_status' => true, 'label' => 'Example RP'],
    'private' => ['public_status' => false],
    'unsafe' => ['url' => 'http://untrusted.example.test/txbridge', 'key_id' => 'wordpress', 'secret' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'],
]);
final class WP_Error {
    public function __construct(public string $code, public string $message, public array $data = []) {}
}
final class WP_REST_Response {
    public function __construct(public mixed $data, public int $status = 200, public array $headers = []) {}
}
final class WP_REST_Request implements ArrayAccess {
    public function __construct(public array $params = [], public array $headers = [], public string $body = '') {}
    public function get_header(string $key): string { return $this->headers[strtolower($key)] ?? ''; }
    public function get_body(): string { return $this->body; }
    public function get_param(string $key): mixed { return $this->params[$key] ?? null; }
    public function get_json_params(): mixed { return json_decode($this->body, true); }
    public function offsetExists(mixed $offset): bool { return isset($this->params[$offset]); }
    public function offsetGet(mixed $offset): mixed { return $this->params[$offset] ?? null; }
    public function offsetSet(mixed $offset, mixed $value): void { $this->params[$offset] = $value; }
    public function offsetUnset(mixed $offset): void { unset($this->params[$offset]); }
}
$routes = []; $hookCount = 0; $admin = false; $httpCalls = []; $httpResponse = ['code' => 200, 'body' => '{"ok":true,"data":{"healthy":true}}'];
function register_activation_hook(...$args): void {}
function register_deactivation_hook(...$args): void {}
function add_action(...$args): void {}
function add_shortcode(...$args): void {}
function register_rest_route($ns, $path, $args): void { global $routes; $routes[$path] = $args; }
function current_user_can($cap): bool { global $admin; return $admin && $cap === 'manage_options'; }
function wp_parse_url($url): array|false { return parse_url($url); }
function wp_json_encode($data): string|false { return json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); }
function is_wp_error($value): bool { return $value instanceof WP_Error; }
function wp_remote_request($url, $options): mixed { global $httpCalls, $httpResponse; $httpCalls[] = compact('url', 'options'); return $httpResponse; }
function wp_remote_retrieve_response_code($r): int { return $r['code']; }
function wp_remote_retrieve_body($r): string { return $r['body']; }
function do_action(...$args): void { global $hookCount; $hookCount++; }
function shortcode_atts($default, $attrs, ...$rest): array { return array_merge($default, $attrs); }
function wp_enqueue_script(...$args): void {}
function plugins_url($path, $file): string { return 'https://wp.example.test/wp-content/plugins/txbridge-wordpress/' . $path; }
function rest_url($path): string { return 'https://wp.example.test/wp-json/' . $path; }
function esc_url($text): string { return htmlspecialchars($text, ENT_QUOTES, 'UTF-8'); }
function esc_html($text): string { return htmlspecialchars($text, ENT_QUOTES, 'UTF-8'); }
function wp_clear_scheduled_hook(...$args): void {}

final class FakeDB {
    public string $prefix = 'wp_';
    public array $events = [];
    public bool $fail = false;
    public array $lastQuery = [];
    public function prepare(string $sql, mixed ...$args): array { return compact('sql', 'args'); }
    public function query(array|string $q): int|false {
        if ($this->fail) { return false; }
        $this->lastQuery = is_array($q) ? $q : ['sql' => $q, 'args' => []];
        if (str_starts_with($this->lastQuery['sql'], 'INSERT IGNORE')) {
            $a = $this->lastQuery['args']; $key = $a[0] . ':' . $a[1];
            if (isset($this->events[$key])) { return 0; }
            $this->events[$key] = ['id' => count($this->events) + 1, 'server' => $a[0], 'event' => $a[1], 'sequence' => $a[2], 'type' => $a[3], 'time' => $a[4], 'hash' => $a[6], 'payload' => $a[7]];
            return 1;
        }
        return 1;
    }
    public function get_var(array $q): mixed {
        $a = $q['args'];
        if (str_contains($q['sql'], 'SELECT payload_hash')) { return $this->events[$a[0] . ':' . $a[1]]['hash'] ?? null; }
        $rows = array_filter($this->events, fn($e) => $e['server'] === $a[0] && $e['type'] === 'bridge.status');
        usort($rows, fn($a, $b) => $b['sequence'] <=> $a['sequence']);
        return $rows[0]['payload'] ?? null;
    }
    public function get_results(array $q, $mode): array {
        $this->lastQuery = $q; $a = $q['args'];
        $rows = array_filter($this->events, fn($e) => $e['server'] === $a[0] && $e['id'] > $a[1]);
        usort($rows, fn($a, $b) => $a['id'] <=> $b['id']);
        return array_slice($rows, 0, $a[2]);
    }
}
$wpdb = new FakeDB();
require_once __DIR__ . '/../wordpress/txbridge-wordpress/txbridge-wordpress.php';
$passed = 0; $failed = 0;
function check(bool $ok, string $message = 'Assertion failed'): void { if (!$ok) { throw new RuntimeException($message); } }
function test(string $name, callable $fn): void {
    global $passed, $failed;
    try { $fn(); $passed++; echo "PASS $name\n"; }
    catch (Throwable $e) { $failed++; echo "FAIL $name: {$e->getMessage()}\n"; }
}
function webhook(int $seq, string $type = 'bridge.status', array $data = [], ?int $at = null): WP_REST_Request {
    $e = ['version' => 1, 'id' => 'main-' . $seq, 'sequence' => $seq, 'serverId' => 'main', 'type' => $type, 'emittedAt' => $at ?? time(), 'data' => (object)$data];
    $body = wp_json_encode($e); $stamp = (string)time();
    return new WP_REST_Request([], ['x-txbridge-server' => 'main', 'x-txbridge-event' => $e['id'], 'x-txbridge-timestamp' => $stamp,
        'x-txbridge-signature' => hash_hmac('sha256', TXBridge_Signing::webhookCanonical('main', $e['id'], $stamp, $body), TXBRIDGE_SERVERS['main']['webhook_secret'])], $body);
}

test('PHP request signature matches independent Python fixture', function() {
    $v = json_decode(file_get_contents(__DIR__ . '/protocol-vectors.json'), true);
    check(hash_hmac('sha256', TXBridge_Signing::canonical($v['server'], $v['key'], $v['method'], $v['path'], $v['timestamp'], $v['nonce'], $v['idempotency'], $v['body']), $v['secret']) === $v['requestSignature']);
});
test('PHP webhook signature matches independent Python fixture', function() {
    $v = json_decode(file_get_contents(__DIR__ . '/protocol-vectors.json'), true);
    check(TXBridge_Signing::verifyWebhook($v['server'], $v['eventId'], $v['timestamp'], $v['webhookSignature'], $v['eventBody'], $v['webhookSecret'], 1700000000));
});
test('all WordPress routes have explicit permissions callbacks', function() { global $routes; TXBridge_WordPress::registerRoutes(); check(count($routes) === 4); foreach ($routes as $r) { check(is_callable($r['permission_callback'])); } });
test('admin endpoint rejects non-administrator', function() { check(!TXBridge_WordPress::authorizeAdmin()); });
test('admin endpoint accepts manage_options capability', function() { global $admin; $admin = true; check(TXBridge_WordPress::authorizeAdmin()); $admin = false; });
test('public status requires explicit opt-in', function() { check(is_wp_error(TXBridge_WordPress::authorizePublic(new WP_REST_Request(['server' => 'private'])))); });
test('public status accepts explicitly public server', function() { check(TXBridge_WordPress::authorizePublic(new WP_REST_Request(['server' => 'main'])) === true); });
test('valid signed webhook is accepted', function() { check(TXBridge_WordPress::authorizeWebhook(webhook(1)) === true); });
test('webhook tampering fails authentication', function() { $r = webhook(2); $r->body .= ' '; check(is_wp_error(TXBridge_WordPress::authorizeWebhook($r))); });
test('unknown webhook server rejected', function() { $r = webhook(2); $r->headers['x-txbridge-server'] = 'unknown'; check(is_wp_error(TXBridge_WordPress::authorizeWebhook($r))); });
test('expired webhook signature rejected', function() { $r = webhook(2); $r->headers['x-txbridge-timestamp'] = (string)(time() - 100); check(is_wp_error(TXBridge_WordPress::authorizeWebhook($r))); });
test('oversized webhook rejected', function() { $r = webhook(2); $r->body = str_repeat('x', 32769); check(is_wp_error(TXBridge_WordPress::authorizeWebhook($r))); });
test('first delivery stores inbox and invokes hook once', function() { global $hookCount; $before = $hookCount; $r = TXBridge_WordPress::webhook(webhook(10, 'bridge.status', ['players' => 12, 'maxPlayers' => 48])); check($r->status === 202); check($hookCount === $before + 1); });
test('duplicate delivery does not rerun hooks', function() { global $hookCount; $request = webhook(11); TXBridge_WordPress::webhook($request); $before = $hookCount; $r = TXBridge_WordPress::webhook($request); check($r->status === 200 && $r->data['duplicate']); check($hookCount === $before); });
test('conflicting same event ID returns 409', function() { $r = TXBridge_WordPress::webhook(webhook(11, 'bridge.status', ['changed' => true])); check($r instanceof WP_Error && $r->data['status'] === 409); });
test('database failure is retryable 503', function() { global $wpdb; $wpdb->fail = true; $r = TXBridge_WordPress::webhook(webhook(12)); check($r instanceof WP_Error && $r->data['status'] === 503); $wpdb->fail = false; });
test('event ID must match signed envelope', function() { $r = webhook(13); $v = json_decode($r->body, true); $v['id'] = 'another'; $r->body = json_encode($v); check(TXBridge_WordPress::webhook($r) instanceof WP_Error); });
test('invalid JSON has explicit error', function() { $r = webhook(13); $r->body = '{'; check(TXBridge_WordPress::webhook($r) instanceof WP_Error); });
test('fractional event sequence rejected', function() { $r = webhook(13); $v = json_decode($r->body, true); $v['sequence'] = 2.5; $r->body = json_encode($v); check(TXBridge_WordPress::webhook($r) instanceof WP_Error); });
test('public snapshot is an allowlist, not the raw event', function() {
    TXBridge_WordPress::webhook(webhook(20, 'bridge.status', ['players' => 15, 'maxPlayers' => 64, 'identifiers' => ['private'], 'hostname' => '<script>secret</script>']));
    $s = TXBridge_WordPress::snapshot('main'); check($s['state'] === 'online' && $s['players'] === 15); check(!str_contains(json_encode($s), 'private')); check(!str_contains(json_encode($s), '<script>'));
});
test('late lower-sequence snapshot cannot roll status back', function() { TXBridge_WordPress::webhook(webhook(19, 'bridge.status', ['players' => 1, 'maxPlayers' => 64])); check(TXBridge_WordPress::snapshot('main')['players'] === 15); });
test('stale data is not reported as live', function() { TXBridge_WordPress::webhook(webhook(21, 'bridge.status', ['players' => 15], time() - 200)); check(TXBridge_WordPress::snapshot('main')['state'] === 'stale'); });
test('unknown server snapshot is unknown, not offline', function() { check(TXBridge_WordPress::snapshot('private')['state'] === 'unknown'); });
test('inbox polling uses receipt cursor for out-of-order delivery', function() { global $wpdb; $r = TXBridge_WordPress::events(new WP_REST_Request(['server' => 'main', 'after' => '0', 'limit' => '100'])); check($r->status === 200); check(str_contains($wpdb->lastQuery['sql'], 'ORDER BY id ASC')); check(isset($r->data['items'][0]['receiptId'])); });
test('inbox invalid limit rejected', function() { check(TXBridge_WordPress::events(new WP_REST_Request(['server' => 'main', 'limit' => '1000'])) instanceof WP_Error); });
test('PHP client uses HTTPS, verifies TLS, disables redirects', function() { global $httpCalls; $r = TXBridge_Client::request('main', 'GET', '/v1/status'); check($r->status === 200); $q = $httpCalls[array_key_last($httpCalls)]; check($q['options']['sslverify'] && $q['options']['redirection'] === 0); check($q['url'] === 'https://bridge.example.test/txbridge/v1/status'); });
test('client signature covers the exact relative path', function() {
    global $httpCalls; TXBridge_Client::request('main', 'GET', '/v1/events?after=0&limit=10'); $q = $httpCalls[array_key_last($httpCalls)]; $h = $q['options']['headers'];
    $expected = hash_hmac('sha256', TXBridge_Signing::canonical('main', 'wordpress', 'GET', '/v1/events?after=0&limit=10', $h['X-TxBridge-Timestamp'], $h['X-TxBridge-Nonce'], '', ''), TXBRIDGE_SERVERS['main']['secret']);
    check(hash_equals($expected, $h['X-TxBridge-Signature']));
});
test('client refuses untrusted HTTP base URL', function() { check(TXBridge_Client::request('unsafe', 'GET', '/v1/status') instanceof WP_Error); });
test('client refuses arbitrary URL forwarding', function() { check(TXBridge_Client::request('main', 'GET', 'https://evil.test') instanceof WP_Error); });
test('client refuses path traversal', function() { check(TXBridge_Client::request('main', 'GET', '/v1/../status') instanceof WP_Error); });
test('client refuses internal txAdmin proxy by default', function() { check(TXBridge_Client::request('main', 'POST', '/v1/txadmin/request', ['route' => 'player_stats'], 'idempotency_php_test_01') instanceof WP_Error); });
test('client requires idempotency key for writes', function() { check(TXBridge_Client::request('main', 'POST', '/v1/actions/announce', ['message' => 'Hi']) instanceof WP_Error); });
test('empty native action body encoded as object', function() { global $httpCalls; TXBridge_Client::request('main', 'POST', '/v1/resources/optional/actions/start', [], 'idempotency_php_test_02'); $q = $httpCalls[array_key_last($httpCalls)]; check($q['options']['body'] === '{}'); });
test('GET request bodies are disallowed', function() { check(TXBridge_Client::request('main', 'GET', '/v1/status', ['x' => 1]) instanceof WP_Error); });
test('client rejects malformed upstream response', function() { global $httpResponse; $old = $httpResponse; $httpResponse = ['code' => 200, 'body' => '<html>login</html>']; check(TXBridge_Client::request('main', 'GET', '/v1/status') instanceof WP_Error); $httpResponse = $old; });
test('private shortcode emits nothing', function() { check(TXBridge_WordPress::shortcode(['server' => 'private']) === ''); });
test('public shortcode contains no shared secrets', function() { $html = TXBridge_WordPress::shortcode(['server' => 'main']); check(str_contains($html, 'data-endpoint')); check(!str_contains($html, TXBRIDGE_SERVERS['main']['secret'])); });
echo "PHP tests: $passed passed, $failed failed\n";
exit($failed ? 1 : 0);
