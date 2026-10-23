import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const source = readFileSync(fileURLToPath(new URL('../app/SourcesTV/TVPlayerView.swift', import.meta.url)), 'utf8');
function method(name) {
  const start = source.indexOf(`private func ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  const open = source.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0, `unbalanced ${name}`);
  return source.slice(open + 1, end - 1).replace(/\/\/[^\n]*/g, '').replace(/\s+/g, ' ').trim();
}

test('both playback prompts use one renderer with their existing layout metrics', () => {
  for (const [name, horizontal, vertical] of [['upNextButton', 24, 13], ['stillWatchingButton', 28, 14]]) {
    assert.equal(method(name), `playbackPromptButton(title, systemImage: systemImage, highlighted: highlighted, horizontalPadding: ${horizontal}, verticalPadding: ${vertical})`);
  }
});

test('shared renderer retains the current theme, glass, typography and reduced-motion treatment', () => {
  assert.equal(method('playbackPromptButton'), [
    'HStack(spacing: 8) { if let img = systemImage { Image(systemName: img) } Text(title).lineLimit(1) }',
    '.font(.headline.weight(.semibold))',
    '.foregroundStyle(highlighted ? Theme.Palette.onAccent : Theme.Palette.textPrimary)',
    '.padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)',
    '.background { if highlighted { Capsule().fill(Theme.Palette.accent) } }',
    '.vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .flat)',
    '.overlay(Capsule().stroke(Theme.Palette.canvas, lineWidth: highlighted ? 3 : 0))',
    '.scaleEffect(accessibilityReduceMotion ? 1.0 : (highlighted ? 1.06 : 1.0))',
    '.fixedSize(horizontal: true, vertical: false)',
  ].join(' '));
});

test('remote-driven callers retain existing titles, selection bindings and icon choices', () => {
  for (const call of [
    'upNextButton("Play Now", systemImage: "play.fill", highlighted: !upNextWantsCredits)',
    'upNextButton("Watch Credits", systemImage: nil, highlighted: upNextWantsCredits)',
    'stillWatchingButton("Continue", systemImage: "play.fill", highlighted: !stillWatchingWantsStop)',
    'stillWatchingButton("Stop", systemImage: nil, highlighted: stillWatchingWantsStop)',
  ]) assert.ok(source.includes(call), call);
});
