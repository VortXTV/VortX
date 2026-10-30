// SOURCE ONLY: invoked by the retained native fixture runner when execution is authorized.
// No compiler/process/network action belongs in this exact declaration extractor.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const [root, output] = process.argv.slice(2);
if (!root || !output) throw new Error('root and existing retained output directory required');
const owner = 'app/SourcesShared/CoreBridge.swift';
const templatePath = 'app/Tests/XperienceNativeNotificationFixture.swift.in';
const source = readFileSync(path.join(root, owner), 'utf8');
const template = readFileSync(path.join(root, templatePath), 'utf8');
const hash = value => createHash('sha256').update(value).digest('hex');
function section(start, end) {
  if (source.split(start).length !== 2) throw new Error('callback source marker drift');
  const first = source.indexOf(start), last = source.indexOf(end, first + start.length);
  if (last <= first) throw new Error('callback range drift');
  return source.slice(first, last);
}
function line(exact) {
  if (source.split(exact).length !== 2) throw new Error('callback declaration drift');
  return exact;
}
const declarations = [
  ['/*__ACTUAL_NATIVE_CALLBACK_LIFETIME__*/', section('private struct NativeCallbackLifetime: Sendable {', '\nextension CoreBridge {')],
  ['/*__ACTUAL_CONTEXT_NOTIFICATION_NAME__*/', line('    static let xperienceContextChangedNote = Notification.Name("vortx.xperienceContextChanged")')],
  ['/*__ACTUAL_PUBLICATION_TOKEN__*/', line('    private struct PublicationToken: Equatable, Sendable { let epoch: UInt64 }')],
  ['/*__ACTUAL_NATIVE_CALLBACK_ORIGIN_AND_MAILBOX__*/', section('    private struct NativeCallbackOrigin: Sendable {', '    /// The only object crossing the callback executor boundary')],
  ['/*__ACTUAL_MAKE_NATIVE_SOURCE_CALLBACK__*/', section('    @MainActor private func makeNativeSourceCallback(', '    /// Source-owned activation closes the unisolated singleton initializer seam.')]
];
let result = template;
for (const [marker, declaration] of declarations) {
  if (result.split(marker).length !== 2) throw new Error('fixture template marker drift');
  result = result.replace(marker, declaration);
}
if (result.includes('/*__ACTUAL_')) throw new Error('unfilled callback declaration');
writeFileSync(path.join(output, 'XperienceNativeNotificationFixture.swift'), result, { flag: 'wx' });
writeFileSync(path.join(output, 'xperience-native-notification-inputs.json'), JSON.stringify({
  owner, ownerSHA256: hash(source), templatePath, templateSHA256: hash(template),
  declarations: declarations.map(([marker, declaration]) => ({ marker, sha256: hash(declaration), bytes: Buffer.byteLength(declaration) })),
  declarationTransformations: [], generatedSHA256: hash(result),
  scope: 'literal production callback/lifetime/origin/mailbox; actual Session/Facade/Store; context/downstream collaborators only'
}, null, 2) + '\n', { flag: 'wx' });
