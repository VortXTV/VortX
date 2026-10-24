const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const repo = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(repo,'app/build'), {recursive:true});
const out = fs.mkdtempSync(path.join(repo,'app/build/profile-glass-controls.'));
const allowed = path.join(repo, 'app', 'build') + path.sep;
if (!out.startsWith(allowed)) throw new Error('Output must stay under exact worktree app/build');
const read = relative => fs.readFileSync(path.join(repo, relative), 'utf8');
function block(source, marker) {
  const begin = source.indexOf(marker);
  if (begin < 0) throw new Error(`Missing declaration ${marker}`);
  let cursor = source.indexOf('{', begin), depth = 0, quoted = false, escaped = false, line = false, comment = 0;
  for (; cursor < source.length; cursor++) {
    const a = source[cursor], b = source[cursor + 1];
    if (line) { if (a === '\n') line = false; continue; }
    if (comment) { if (a === '/' && b === '*') { comment++; cursor++; } else if (a === '*' && b === '/') { comment--; cursor++; } continue; }
    if (quoted) { if (escaped) escaped = false; else if (a === '\\') escaped = true; else if (a === '"') quoted = false; continue; }
    if (a === '/' && b === '/') { line = true; cursor++; continue; }
    if (a === '/' && b === '*') { comment++; cursor++; continue; }
    if (a === '"') { quoted = true; continue; }
    if (a === '{') depth++;
    if (a === '}' && --depth === 0) return source.slice(begin, cursor + 1);
  }
  throw new Error(`Unterminated declaration ${marker}`);
}
const theme = read('app/SourcesShared/Theme.swift');
const manager = read('app/SourcesShared/ThemeManager.swift');
const root = read('app/SourcesiOS/iOSRootView.swift');
const accents = manager.slice(manager.indexOf('static let accents: [AccentOption] = ['), manager.indexOf('\n    private var option:'));
if ((accents.match(/AccentOption\(id:/g) || []).length !== 9) throw new Error('Nine current source accents required');
const shellAdopted = root.includes('struct CinemaCompactNavigationShell<');
if(!shellAdopted) throw Error('Shipping shared shell missing');
const shell = block(root, 'struct CinemaCompactNavigationShell<');
const members = ['private var option:', 'var accent:', 'var accentBright:', 'var onAccent:',
  'private var accentLuminance:', 'var canvas:', 'var surface1:', 'var surface2:', 'var surface3:',
  'var hairline:', 'var glassVeil:', 'private func tintedDark('].map(marker => block(manager, marker)).join('\n');
const generated = `import SwiftUI\nimport AppKit\n
private func themeRGB(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red:r, green:g, blue:b, opacity:1) }
${block(manager, 'struct AccentOption:')}
// Inert RAM-only ObservableObject palette compatibility; actual production color members follow.
@MainActor final class ThemeManager: ObservableObject {
  static let shared = ThemeManager()
  @Published var accentID = "vortx"
  @Published var oled = true
  let textScale = 1.0
  ${accents}
  ${members}
}
enum Theme { ${['enum Palette', 'enum Space', 'enum Radius', '@MainActor enum Typography', 'enum Motion'].map(x => block(theme,x)).join('\n')} }
${shell}
${block(root, 'struct CinemaTabBarChrome<')}
${block(root, 'struct CinemaCompactTabLabel:')}
`;
fs.writeFileSync(path.join(out, 'ProductionControls.swift'), generated);
const files = ['app/SourcesShared/GlassStyle.swift','app/SourcesShared/ChipButtonStyle.swift','app/SourcesShared/Theme.swift',
  'app/SourcesShared/ThemeManager.swift','app/SourcesiOS/iOSRootView.swift'];
const hashes = Object.fromEntries(files.map(file => [file, crypto.createHash('sha256').update(read(file)).digest('hex')]));
fs.writeFileSync(path.join(out, 'profile-controls-extraction.json'), JSON.stringify({
  sourceHead:cp.execFileSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).trim(), hashes,
  shellOrigin:shellAdopted?'shipping production declaration':'generated proposal pending integration',
  note:'Actual GlassStyle and ChipButtonStyle compiled as files; exact extracted Theme/root components with RAM-only ObservableObject palette. Public underscored SDK accessibility setters are fixture-only. No device/native navigation receipt.'
},null,2)+'\n');
process.stdout.write(`Prepared only: ${out}\nCompile serially after root grants compiler slot with ProductionControls.swift, current GlassStyle.swift, current ChipButtonStyle.swift, and ProfileGlassControlRenderingTests.swift.\n`);

const args=['swiftc','-j','2','-Onone','-parse-as-library',path.join(out,'ProductionControls.swift'),path.join(repo,'app/SourcesShared/GlassStyle.swift'),path.join(repo,'app/SourcesShared/ChipButtonStyle.swift'),path.join(repo,'app/SourcesShared/VisualEffects.swift'),path.join(repo,'app/SourcesShared/ReducedMotion.swift'),path.join(repo,'app/Tests/ProfileGlassControlRenderingTests.swift'),'-o',path.join(out,'fixture')];
const built=cp.spawnSync('xcrun',args,{encoding:'utf8'});fs.writeFileSync(path.join(out,'compiler.log'),(built.stdout??'')+(built.stderr??''));
if(built.status!==0){process.stderr.write(built.stderr??'');process.exit(1);}
const run=cp.spawnSync(path.join(out,'fixture'),[repo,out],{encoding:'utf8'});fs.writeFileSync(path.join(out,'runtime.log'),(run.stdout??'')+(run.stderr??''));
const sourceUnchanged=files.every(f=>crypto.createHash('sha256').update(read(f)).digest('hex')===hashes[f]);
fs.writeFileSync(path.join(out,'result-receipt.json'),JSON.stringify({compilerExit:built.status,runtimeExit:run.status,sourceUnchanged,passed:run.status===0&&sourceUnchanged},null,2)+'\n');
process.stdout.write(run.stdout??'');process.stderr.write(run.stderr??'');if(run.status!==0||!sourceUnchanged)process.exit(1);

