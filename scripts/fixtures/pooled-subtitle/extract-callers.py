#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import sys

root, fixture, output = map(Path, sys.argv[1:])
receipts = {}

def source(path):
    text = (root / path).read_text()
    receipts[path] = hashlib.sha256(text.encode()).hexdigest()
    return text

def declaration(text, marker):
    assert text.count(marker) == 1, f'missing/nonunique declaration {marker}'
    start = text.index(marker)
    opening = start + len(marker) - 1 if marker.endswith('{') else text.index('{', start + len(marker))
    mode = 'code'
    depth = 0
    blocks = 0
    i = opening
    while i < len(text):
        c, n = text[i], text[i + 1:i + 2]
        if mode == 'line':
            if c == '\n': mode = 'code'
        elif mode == 'block':
            if c == '/' and n == '*': blocks += 1; i += 1
            elif c == '*' and n == '/':
                blocks -= 1; i += 1
                if blocks == 0: mode = 'code'
        elif mode == 'string':
            if c == '\\': i += 1
            elif c == '"': mode = 'code'
        elif c == '/' and n == '/': mode = 'line'; i += 1
        elif c == '/' and n == '*': mode = 'block'; blocks = 1; i += 1
        elif text.startswith('"""', i) or (c == '#' and n == '"'):
            raise RuntimeError(f'unsupported string literal in selected declaration: {marker}')
        elif c == '"': mode = 'string'
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return text[start:i + 1].replace('private func ', 'func ', 1)
        i += 1
    raise RuntimeError(f'unclosed declaration: {marker}')

apple = source('app/Sources/PlayerScreen.swift')
tv = source('app/SourcesTV/TVPlayerView.swift')
pool = source('app/SourcesShared/SubtitlePoolClient.swift')
engine = source('app/Sources/Player/PlayerEngine.swift')
policy = source('app/SourcesShared/PooledSubtitleSelectionPolicy.swift')
replacements = {
    '// INSERT_POLICY': policy,
    '// INSERT_PRESENTATION': '@MainActor\n' + declaration(engine, 'struct SubtitleAlignmentPresentationRequest {'),
    '// INSERT_FENCE': declaration(pool, '    struct PublicationFence: Sendable {'),
    '// INSERT_LEDGER': declaration(pool, '    struct RequestOwnership: Sendable {'),
    '// INSERT_INVALIDATE': declaration(apple, '    private func invalidateSubtitleAlignmentPresentation()'),
    '// INSERT_PUBLICATION': declaration(apple, '    private func permitsSubtitlePublication('),
}
for tag, text in [('APPLE', apple), ('TV', tv)]:
    replacements[f'// INSERT_{tag}_CALLERS'] = '\n'.join([
        declaration(text, '    private func selectPooledSubtitle('),
        declaration(text, '    private func selectAutomaticPooledSubtitle('),
    ])
result = fixture.read_text()
for marker, replacement in replacements.items():
    assert result.count(marker) == 1
    result = result.replace(marker, replacement)
assert '// INSERT_' not in result
output.write_text(result)
output.with_suffix('.inputs.json').write_text(json.dumps(receipts, indent=2) + '\n')
