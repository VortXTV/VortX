import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

function skipLineComment(text, start) {
  const end = text.indexOf('\n', start + 2);
  return end < 0 ? text.length : end + 1;
}
function skipBlockComment(text, start) {
  let depth = 1;
  for (let cursor = start + 2; cursor < text.length;) {
    if (text.startsWith('/*', cursor)) { depth++; cursor += 2; }
    else if (text.startsWith('*/', cursor)) {
      cursor += 2;
      if (--depth === 0) return cursor;
    } else cursor++;
  }
  throw new Error('Unterminated Kotlin block comment');
}
function skipQuoted(text, start) {
  const quote = text[start];
  const triple = quote === '"' && text.startsWith('"""', start);
  const delimiter = triple ? '"""' : quote;
  for (let cursor = start + delimiter.length; cursor < text.length;) {
    if (text.startsWith(delimiter, cursor)) return cursor + delimiter.length;
    if (!triple && quote !== '`' && text[cursor] === '\\') { cursor += 2; continue; }
    // Kotlin template expressions can contain their own strings, comments and braces.
    if (quote === '"' && text.startsWith('${', cursor)) {
      cursor = balancedBlockEnd(text, cursor + 1);
      continue;
    }
    cursor++;
  }
  throw new Error('Unterminated Kotlin quoted literal');
}
function nonCodeEnd(text, cursor) {
  if (text.startsWith('//', cursor)) return skipLineComment(text, cursor);
  if (text.startsWith('/*', cursor)) return skipBlockComment(text, cursor);
  if (text[cursor] === '"' || text[cursor] === "'" || text[cursor] === '`') return skipQuoted(text, cursor);
  return null;
}
function balancedBlockEnd(text, opening) {
  assert.equal(text[opening], '{', 'Kotlin block must start at its opening brace');
  let depth = 1;
  for (let cursor = opening + 1; cursor < text.length;) {
    const skipped = nonCodeEnd(text, cursor);
    if (skipped != null) { cursor = skipped; continue; }
    if (text[cursor] === '{') depth++;
    else if (text[cursor] === '}' && --depth === 0) return cursor + 1;
    cursor++;
  }
  throw new Error('Unterminated Kotlin method block');
}

/** Extract one literal block/expression-bodied Kotlin boundary. Whitespace/indentation are not syntax. */
export function method(text, marker) {
  const start = text.indexOf(marker);
  assert(start >= 0 && text.indexOf(marker, start + marker.length) < 0, `Missing/ambiguous ${marker}`);
  for (let cursor = start + marker.length; cursor < text.length;) {
    const skipped = nonCodeEnd(text, cursor);
    if (skipped != null) { cursor = skipped; continue; }
    if (text[cursor] === '{') return text.slice(start, balancedBlockEnd(text, cursor)) + '\n';
    cursor++;
  }
  throw new Error(`Missing Kotlin method block ${marker}`);
}

// The recovery fixture generator calls the same parser as the maintained source verifier.
if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  const input = JSON.parse(readFileSync(0, 'utf8'));
  process.stdout.write(method(input.text, input.marker));
}
