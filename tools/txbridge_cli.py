#!/usr/bin/env python3
"""Dependency-free signed txBridge client. Secrets are read from the environment."""
from __future__ import annotations
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward a signature or credentials to a redirect target.


def validate_target(base: str, path: str, allow_loopback_http: bool = False) -> str:
    parsed = urllib.parse.urlsplit(base)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname:
        raise ValueError('Use a configured base URL without credentials, query or fragment.')
    if re.search(r'[\s\\]', base) or '%' in parsed.netloc:
        raise ValueError('Invalid base URL.')
    if parsed.scheme != 'https':
        if not (allow_loopback_http and parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', '::1')):
            raise ValueError('HTTPS required; local development needs --allow-loopback-http.')
    if not re.fullmatch(r'/v1/[A-Za-z0-9_/-]+(?:\?[A-Za-z0-9_%~.=+&-]+)?', path) or len(path) > 4096 or '//' in path.split('?', 1)[0]:
        raise ValueError('Use an unencoded resource-relative /v1/ path, not a complete URL.')
    return base.rstrip('/') + path


def request_headers(server: str, key: str, secret: str, method: str, path: str,
                    body: bytes, idem: str = '', timestamp: str | None = None,
                    nonce: str | None = None) -> dict[str, str]:
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', server) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', key):
        raise ValueError('Invalid server or key ID.')
    if len(secret) < 32 or len(secret) > 256 or re.search(r'[\x00-\x1f\x7f]', secret):
        raise ValueError('Configure a 32–256 character shared secret in TXBRIDGE_SECRET.')
    if method not in ('GET', 'POST') or (method == 'GET' and body):
        raise ValueError('Only GET without a body and POST are supported.')
    if method == 'POST' and not re.fullmatch(r'[A-Za-z0-9_-]{16,128}', idem):
        raise ValueError('Every POST needs an explicit --idempotency-key (16–128 characters).')
    if len(body) > 32768:
        raise ValueError('Body exceeds 32 KiB.')
    timestamp = timestamp or str(int(time.time()))
    nonce = nonce or secrets.token_hex(24)
    canonical = '\n'.join(('TXBRIDGE1', server, key, method, path, timestamp, nonce, idem,
                           hashlib.sha256(body).hexdigest()))
    signature = hmac.new(secret.encode('utf-8'), canonical.encode('utf-8'), hashlib.sha256).hexdigest()
    result = {'X-TxBridge-Key': key, 'X-TxBridge-Timestamp': timestamp,
              'X-TxBridge-Nonce': nonce, 'X-TxBridge-Signature': signature,
              'Accept': 'application/json'}
    if method == 'POST':
        result.update({'Content-Type': 'application/json', 'Idempotency-Key': idem})
    return result


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('method', choices=['GET', 'POST'])
    p.add_argument('path', help='For example /v1/status; omit the /txbridge resource prefix.')
    p.add_argument('--url', default=os.environ.get('TXBRIDGE_URL', ''))
    p.add_argument('--server', default=os.environ.get('TXBRIDGE_SERVER', 'main'))
    p.add_argument('--key', default=os.environ.get('TXBRIDGE_KEY', 'wordpress'))
    p.add_argument('--body-file', type=Path, help='Exact UTF-8 JSON object bytes to sign and send.')
    p.add_argument('--idempotency-key', default='')
    p.add_argument('--allow-loopback-http', action='store_true', help='Development only: numeric localhost HTTP.')
    args = p.parse_args(argv)
    try:
        url = validate_target(args.url, args.path, args.allow_loopback_http)
        body = args.body_file.read_bytes() if args.body_file else (b'{}' if args.method == 'POST' else b'')
        if args.method == 'POST' and not isinstance(json.loads(body), dict):
            raise ValueError('POST body must be a JSON object.')
        headers = request_headers(args.server, args.key, os.environ.get('TXBRIDGE_SECRET', ''),
                                  args.method, args.path, body, args.idempotency_key)
        request = urllib.request.Request(url, data=body if args.method == 'POST' else None,
                                         headers=headers, method=args.method)
        opener = urllib.request.build_opener(NoRedirect())
        try:
            response = opener.open(request, timeout=20)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            raw = response.read(524289)
            if len(raw) > 524288:
                raise ValueError('Response exceeds the 512 KiB client limit.')
            try:
                decoded = json.loads(raw)
            except (ValueError, UnicodeError) as exc:
                raise ValueError('Bridge did not return JSON (check the proxy path and TLS).') from exc
            print(json.dumps(decoded, indent=2, ensure_ascii=False))
            return 0 if 200 <= response.status < 300 and isinstance(decoded, dict) and decoded.get('ok') is True else 1
    except (OSError, ValueError, urllib.error.URLError) as exc:
        # Never dump request headers, environment variables or credentials.
        print(f'txBridge request failed: {exc}. Reconcile an ambiguous write before retrying.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
