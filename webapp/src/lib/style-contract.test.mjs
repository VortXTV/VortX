import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// Source contracts for shared chip and semantic text definitions; these do not measure browser
// rendering, profile tint contrast, glass composition, or device responsiveness.
// The desktop app runs this same web client, so this one stylesheet is every shell's palette.
const css = readFileSync(new URL('../styles/app.css', import.meta.url), 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '');

function rootColour(source, name) {
  const root = /^:root\s*\{([^}]+)\}/m.exec(source);
  assert.ok(root, 'Retain an explicit root palette');
  const declarations = [...root[1].matchAll(new RegExp(`${name}:\\s*(#[0-9a-f]{6})\\s*;`, 'gi'))];
  assert.equal(declarations.length, 1, `Keep one root value for ${name}`);
  return declarations[0][1].toLowerCase();
}

function luminance(hex) {
  const [red, green, blue] = hex.slice(1).match(/../g).map((pair) => {
    const component = parseInt(pair, 16) / 255;
    return component <= 0.04045 ? component / 12.92 : ((component + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

test('semantic text clears 4.5:1 on each declared opaque dark surface', () => {
  for (const textName of ['--muted', '--muted-2']) {
    const text = luminance(rootColour(css, textName));
    for (const backgroundName of ['--bg', '--surface', '--surface-2', '--surface-3']) {
      const background = luminance(rootColour(css, backgroundName));
      const contrast = (Math.max(text, background) + 0.05) / (Math.min(text, background) + 0.05);
      assert.ok(contrast >= 4.5, `${textName} on ${backgroundName}: ${contrast.toFixed(3)}:1`);
    }
  }
});

function sharedChipRule() {
  const matches = [...css.matchAll(/\.btn-chip,\s*\.chip\s*\{([^}]+)\}/g)];
  assert.equal(matches.length, 1, 'Keep one authoritative shared chip base');
  return matches[0][1];
}

test('chip base styling has one shared owner instead of a discarded duplicate', () => {
  const shared = sharedChipRule();
  assert.equal([...css.matchAll(/(?:^|\})\s*\.chip\s*\{/g)].length, 0,
    'A standalone chip base duplicates the later design-system definition');
  for (const declaration of ['display: inline-flex', 'gap: 0.45rem',
    'padding: 0.62rem 1rem', 'background: var(--surface-2)', 'color: var(--text)']) {
    assert.ok(shared.includes(declaration), `Missing chip contract: ${declaration}`);
  }
});

test('disabled chips override selected, hover and press affordances together', () => {
  const selected = css.indexOf('.btn-chip.selected, .chip.selected');
  const disabled = /\.btn-chip:disabled,\s*\.chip:disabled\s*\{([^}]+)\}/.exec(css);
  assert.ok(selected >= 0 && disabled, 'Retain selected and shared disabled states');
  assert.ok(disabled.index > selected, 'Disabled styling must follow selected styling');
  for (const declaration of ['background: var(--surface-2)', 'color: var(--muted)',
    'box-shadow: none', 'cursor: default', 'transform: none']) {
    assert.ok(disabled[1].includes(declaration), `Missing disabled contract: ${declaration}`);
  }
});
