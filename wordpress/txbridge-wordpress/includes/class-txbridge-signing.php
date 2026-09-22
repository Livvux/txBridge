<?php
/** Shared wire protocol. No WordPress dependencies; also used by protocol tests. */
declare(strict_types=1);
final class TXBridge_Signing {
    public static function canonical(string $server, string $key, string $method, string $path, string $timestamp, string $nonce, string $idem, string $body): string {
        return implode("\n", ['TXBRIDGE1', $server, $key, $method, $path, $timestamp, $nonce, $idem, hash('sha256', $body)]);
    }
    public static function webhookCanonical(string $server, string $event, string $timestamp, string $body): string {
        return implode("\n", ['TXBRIDGE-WEBHOOK1', $server, $event, $timestamp, hash('sha256', $body)]);
    }
    public static function headers(string $server, string $key, string $secret, string $method, string $path, string $body, string $idem = ''): array {
        $stamp = (string) time();
        $nonce = bin2hex(random_bytes(24));
        return [
            'Content-Type' => 'application/json',
            'X-TxBridge-Key' => $key,
            'X-TxBridge-Timestamp' => $stamp,
            'X-TxBridge-Nonce' => $nonce,
            'X-TxBridge-Signature' => hash_hmac('sha256', self::canonical($server, $key, $method, $path, $stamp, $nonce, $idem, $body), $secret),
            'Idempotency-Key' => $idem,
        ];
    }
    public static function verifyWebhook(string $server, string $event, string $stamp, string $signature, string $body, string $secret, ?int $now = null): bool {
        if (strlen($secret) < 32 || strlen($body) > 32768 || !preg_match('/^[A-Za-z0-9_-]{1,64}$/D', $server)
            || !preg_match('/^[A-Za-z0-9_-]{1,128}$/D', $event) || !preg_match('/^[0-9]{10}$/D', $stamp)
            || abs(($now ?? time()) - (int)$stamp) > 90 || !preg_match('/^[0-9a-f]{64}$/D', $signature)) {
            return false;
        }
        return hash_equals(hash_hmac('sha256', self::webhookCanonical($server, $event, $stamp, $body), $secret), $signature);
    }
}
