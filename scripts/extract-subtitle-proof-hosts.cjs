#!/usr/bin/env node
// Extract actual scalar owner proofs into synthetic host namespaces.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const [rootArg, mode, outputArg] = process.argv.slice(2);
if (!rootArg || !mode || !outputArg || process.argv.length !== 5) throw new Error('usage: extract-subtitle-proof-hosts.cjs ROOT MODE OUTPUT');
const root = fs.realpathSync(rootArg), output = path.resolve(outputArg);
if (!fs.existsSync(path.dirname(output))) throw new Error('output parent must exist');
const buildRoot = fs.realpathSync(path.join(root, 'app/build'));
const relativeBuild = path.relative(root, buildRoot);
if (!relativeBuild || relativeBuild === '..' || relativeBuild.startsWith('../') || path.isAbsolute(relativeBuild)) throw new Error('real app/build escaped repository root');
const realParent = fs.realpathSync(path.dirname(output));
const rel = path.relative(buildRoot, realParent);
if (!rel || rel === '..' || rel.startsWith('../') || path.isAbsolute(rel)) throw new Error('output outside real app/build');
const modes = new Set(['full-shells','bridge-shell','bridge-extension','facade-shell','bridge-extension-facade-shell']);
if (!modes.has(mode)) throw new Error('unsupported composition mode');
const files = { bridge:path.join(root,'app/SourcesShared/CoreBridge.swift'), facade:path.join(root,'app/SourcesShared/VortxNativeCoreFacade.swift'), legacy:path.join(root,'app/SourcesShared/LegacyWatchOwnership.swift') };
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
function declaration(source, marker, owner) {
  const start = source.indexOf(marker);
  if (start < 0 || source.indexOf(marker,start+marker.length) >= 0) throw new Error(owner+': missing/ambiguous actual anchor');
  const open = source.indexOf('{',start+marker.length-1);
  if (open < 0) throw new Error(owner+': missing body');
  let depth=0,state='code',blocks=0,quote='';
  for (let i=open;i<source.length;i++) {
    const c=source[i],n=source[i+1];
    if(state==='line'){if(c==='\n')state='code';continue;}
    if(state==='block'){if(c==='/'&&n==='*'){blocks++;i++;}else if(c==='*'&&n==='/'){blocks--;i++;if(!blocks)state='code';}continue;}
    if(state==='string'){if(c==='\\'){i++;continue;}if(source.startsWith(quote,i)){i+=quote.length-1;state='code';}continue;}
    if(c==='/'&&n==='/'){state='line';i++;continue;}
    if(c==='/'&&n==='*'){state='block';blocks=1;i++;continue;}
    if(c==='"'){quote=source.startsWith('"""',i)?'"""':'"';if(quote.length===3)i+=2;state='string';continue;}
    if(c==='{')depth++;
    if(c==='}'&&--depth===0){
      const text=source.slice(start,i+1).trimEnd()+'\n';
      const normalized=text.replace(/\s+/g,' ').trim();
      const expected=owner==='CoreBridge'
       ?'struct NativeSubtitleOwnerProof: Equatable, Sendable { let domain: UUID let installation: UUID let credential: CredentialScopeRegistry.Capture let sourceID: UUID let profileID: UUID let accountGeneration: UUID let originalApplicationEpoch: UUID fileprivate init(domain: UUID, installation: UUID, credential: CredentialScopeRegistry.Capture, sourceID: UUID, profileID: UUID, accountGeneration: UUID, originalApplicationEpoch: UUID) { self.domain = domain; self.installation = installation; self.credential = credential self.sourceID = sourceID; self.profileID = profileID; self.accountGeneration = accountGeneration self.originalApplicationEpoch = originalApplicationEpoch } }'
       :'struct NativeSubtitleOwnerProof: Equatable, Sendable { let bridge: CoreBridge.NativeSubtitleOwnerProof let profileGeneration: UUID fileprivate init(bridge: CoreBridge.NativeSubtitleOwnerProof, profileGeneration: UUID) { self.bridge = bridge; self.profileGeneration = profileGeneration } }';
      if(normalized!==expected)throw new Error(owner+': stored field or initializer shape changed');
      return text;
    }
  }
  throw new Error(owner+': unbalanced declaration');
}
const bb=fs.readFileSync(files.bridge),fb=fs.readFileSync(files.facade),lb=fs.readFileSync(files.legacy),legacyText=lb.toString('utf8'),facadeText=fb.toString('utf8');
const epochAnchor='static func applicationEpochIsCurrent(_ expected: UUID) -> Bool {';
if(legacyText.indexOf(epochAnchor)<0||legacyText.indexOf(epochAnchor,legacyText.indexOf(epochAnchor)+epochAnchor.length)>=0)throw new Error('actual LegacyWatchOwnership epoch predicate missing/ambiguous');
const facadeAnchors=[
 'let profileTransition = forceProfileTransition || ["switch_profile", "delete_profile", "merge_native_sync", "patch_profile", "rebind_profile_account"].contains(type)',
 'let subtitleOwnerTransition = profileTransition || forceSubtitleOwnerTransition\n            || ["add_profile", "bind_sync_scope"].contains(type) || ownerOperation != nil\n            || legacyMaterial != nil || hostRemote != nil\n            || !websiteEvents.isEmpty || !websiteAddonEvents.isEmpty',
 'forceSubtitleOwnerTransition: Bool = false,',
 'let transitionTypes: Set<String> = ["switch_profile", "delete_profile", "merge_native_sync", "patch_profile", "rebind_profile_account"]',
 'forceSubtitleOwnerTransition: true,'
];
for(const anchor of facadeAnchors){const at=facadeText.indexOf(anchor);if(at<0||facadeText.indexOf(anchor,at+anchor.length)>=0)throw new Error('actual Facade owner-transition assertion missing/ambiguous: '+anchor);}
const b=declaration(bb.toString('utf8'),'    struct NativeSubtitleOwnerProof: Equatable, Sendable {','CoreBridge');
const f=declaration(fb.toString('utf8'),'    struct NativeSubtitleOwnerProof: Equatable, Sendable {','VortxNativeCoreFacade');
const ind=s=>s.trimEnd().split('\n').map(x=>'    '+x).join('\n');
const bi=ind(b),fi=ind(f);
const outputs={
 'full-shells':'import Foundation\nenum CoreBridge {\n'+bi+'\n}\nenum VortxNativeCoreFacade {\n'+fi+'\n}\n',
 'bridge-shell':'import Foundation\nenum CoreBridge {\n'+bi+'\n}\n',
 'bridge-extension':'import Foundation\nextension CoreBridge {\n'+bi+'\n}\n',
 'facade-shell':'import Foundation\nenum VortxNativeCoreFacade {\n'+fi+'\n}\n',
 'bridge-extension-facade-shell':'import Foundation\nextension CoreBridge {\n'+bi+'\n}\nenum VortxNativeCoreFacade {\n'+fi+'\n}\n'
};
const proof=Buffer.from(outputs[mode]||'');
if(!proof.length)throw new Error('unsupported composition mode');
const bytes=Buffer.concat([lb,Buffer.from('\n'),proof.subarray(Buffer.byteLength('import Foundation\n'))]);
fs.writeFileSync(output,bytes,{flag:'wx'});
process.stdout.write(JSON.stringify({mode,output,generatedSHA256:hash(bytes),legacySource:{path:path.relative(root,files.legacy),sourceSHA256:hash(lb),included:'complete actual source'},declarations:[
 {path:path.relative(root,files.bridge),sourceSHA256:hash(bb),declarationSHA256:hash(Buffer.from(b))},
 {path:path.relative(root,files.facade),sourceSHA256:hash(fb),declarationSHA256:hash(Buffer.from(f))}
]},null,2)+'\n');
