#!/usr/bin/env python3
"""Compare txAdmin route registrations and documented event names against this release.
This checks the integration surface, not handler bodies, permissions, or runtime compatibility.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ROUTER = 'core/modules/WebServer/router.ts'
EVENTS = 'docs/events.md'


def parse_routes(text: str) -> set[tuple[str, str, str, str]]:
    # txAdmin's audited router uses single-line registrations. Strip comments first.
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
    return set((method.upper(), path, middleware or 'none', handler) for method, path, middleware, handler in
               re.findall(r"router\.(get|post)\(\s*'([^']+)'\s*,\s*(?:(\w+)\s*,\s*)?routes\.(\w+)\s*\)", text))


def parse_events(text: str) -> tuple[set[str], set[str]]:
    current, _, deprecated = text.partition('## Deprecated Events')
    pattern = r'^### txAdmin:events:([A-Za-z0-9_]+)\s*$'
    return set(re.findall(pattern, current, re.M)), set(re.findall(pattern, deprecated, re.M))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, help='Local txAdmin checkout, for an offline audit.')
    parser.add_argument('--ref', default='master', help='Remote git ref to inspect (default master).')
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', args.ref):
        parser.error('Invalid ref; use a branch, tag or commit without slash characters.')
    def read(path: str) -> str:
        if args.source_root:
            return (args.source_root / path).read_text(encoding='utf-8')
        request = urllib.request.Request(f'https://raw.githubusercontent.com/citizenfx/txAdmin/{args.ref}/{path}',
                                         headers={'User-Agent': 'txBridge-surface-audit/0.1.0'})
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read(2_000_000).decode('utf-8')
    try:
        catalog = json.loads((ROOT / 'docs/txadmin-routes.json').read_text())
        events = json.loads((ROOT / 'docs/txadmin-events.json').read_text())
        expected = {(r['method'], r['path'], r['middleware'], r['handler']) for r in catalog['routes']}
        actual = parse_routes(read(ROUTER))
        observed, old = parse_events(read(EVENTS))
        report = {
            'auditedRevision': catalog['ref'], 'target': str(args.source_root) if args.source_root else args.ref,
            'routeCount': len(actual), 'addedRoutes': sorted(actual - expected), 'removedOrChangedRoutes': sorted(expected - actual),
            'addedEvents': sorted(observed - set(events['current'])), 'removedEvents': sorted(set(events['current']) - observed),
            'addedDeprecatedEvents': sorted(old - set(events['deprecated'])), 'removedDeprecatedEvents': sorted(set(events['deprecated']) - old),
            'limitation': 'Matching names do not verify request schemas, permissions, authentication, or runtime behavior.',
        }
        print(json.dumps(report, indent=2))
        return 1 if any(report[k] for k in ('addedRoutes', 'removedOrChangedRoutes', 'addedEvents', 'removedEvents', 'addedDeprecatedEvents', 'removedDeprecatedEvents')) else 0
    except (OSError, ValueError) as exc:
        print(f'Could not audit upstream: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
