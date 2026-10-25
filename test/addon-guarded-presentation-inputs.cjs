'use strict';
// Consumes caller-conserved bytes only. No FS/process/parser/SDK/network calls.
// Deliberately narrow lexical extraction: unsupported prefixes fail closed.
function exact(source, marker, receipts = [], owner = 'app/SourcesShared/CoreBridge.swift') {
    const at = source.indexOf(marker);
    if (at < 0 || source.indexOf(marker, at + marker.length) >= 0) throw Error('Missing/ambiguous: ' + marker);
    let start = source.lastIndexOf('\n', at - 1) + 1;
    const attrs = /^(?:(?:@MainActor|@discardableResult)\s*)+$/;
    const inline = source.slice(start, at).trim();
    if (inline && !attrs.test(inline)) throw Error('Unsupported inline prefix: ' + marker);
    while (start > 0) {
        const prior = source.lastIndexOf('\n', start - 2) + 1;
        if (!attrs.test(source.slice(prior, start).trim())) break;
        start = prior;
    }
    for (const rawLine of source.slice(0, start).split(/\r?\n/).reverse()) {
        const line = rawLine.trim();
        if (!line || line.startsWith('//')) continue;
        if (line.includes('/*') || line.includes('*/') || line.includes('//'))
            throw Error('Unsupported comment/attribute prefix: ' + marker);
        // A closed preceding declaration is a boundary, not an attribute on this declaration.
        // In particular an unrelated one-line @MainActor method may end immediately above us.
        // Attached unsupported attributes still fail below; never strip them from the slice.
        if (line.endsWith('}')) break;
        if (line.includes('@')) throw Error('Unsupported comment/attribute prefix: ' + marker);
        if (line.endsWith('{') || /^import\s/.test(line)
            || /^(?:(?:private|fileprivate|static|internal|public|nonisolated)\s+)*(?:let|var)\s/.test(line)) break;
        throw Error('Unsupported prefix: ' + marker);
    }
    const open = source.indexOf('{', at + marker.length - 1);
    if (open < 0) throw Error('No body: ' + marker);
    let i=open, depth=0, block=0, line=false, quote=null;
    for (; i<source.length; i++) {
        const c=source[i], n=source[i+1];
        if (line) { if(c==='\n') line=false; continue; }
        if (block) { if(c==='/'&&n==='*'){block++;i++;} else if(c==='*'&&n==='/'){block--;i++;} continue; }
        if (quote) { if(source.startsWith(quote.end,i)){i+=quote.end.length-1;quote=null;}
            else if(quote.hashes===''&&c==='\\')i++; continue; }
        if(c==='/'&&n==='/'){line=true;i++;continue;}
        if(c==='/'&&n==='*'){block=1;i++;continue;}
        const literal=source.slice(i).match(/^(#*)("""|")/);
        if(literal){quote={hashes:literal[1],end:literal[2]+literal[1]};i+=literal[0].length-1;continue;}
        if(c==='{')depth++;
        if(c==='}'&&--depth===0){i++;break;}
    }
    if(depth||block||quote)throw Error('Unterminated: '+marker);
    const bytes=source.slice(start,i);
    receipts.push({owner,marker,firstLine:source.slice(0,start).split('\n').length,bytes});
    return bytes;
}
function required(source, texts, label) {
    const accepts = value => texts.every(text => value.includes(text));
    if (!accepts(source)) throw Error('Missing source contract: '+label+': '+texts.filter(t=>!source.includes(t)).join(' | '));
    for(const text of texts)if(accepts(source.replace(text,'REMOVED_SOURCE_CONTRACT')))
        throw Error('Remove-one negative accepted: '+label);
}
// A separate conserved module owns SOURCE-ONLY real Facade/pipeline checks.
// This file only builds the SDK-free exact presentation-owner translation unit.
function guardedPublication(core,cases,receipts=[]) {
    const get=marker=>exact(core,marker,receipts);
    const top=['private struct NativeMetadataSlotProposal:',
        'private struct NativeMetadataEmissionIdentity:'].map(get);
    const nested=['private struct NativeMetadataPresentationProposal:',
        'private struct NativeMetadataPresentationFrame:',
        'private final class NativeMetadataFrameBox:',
        'private final class MetadataPresentation'].map(get);
    const finalVeto='guard isCurrent(),\n'
        +'                  (mutation.touchesMetadata ? metadataProposal : streamsProposal) == attempt,\n'
        +'                  !mutation.touchesStatus || statusProposal == expectedStatus else { return false }\n'
        +'            if let clear { guard ownsClear(clear) else { return false } }';
    if(nested[3].split(finalVeto).length!==2)throw Error('Expected exactly one post-willChange final-store veto');
    // Explicit negative clone ONLY. Positive extracted declarations stay unchanged.
    const negative=nested[3].replace('private final class MetadataPresentation','private final class UnfencedMetadataPresentation')
        .replace(finalVeto,'// NEGATIVE CONTROL ONLY: post-willChange final-store veto removed.');
    const types=['struct StreamAddonState:','private struct StreamAddonStatusRow:',
        'private struct StreamAddonStatusProjection:'].map(get);
    const members=['private static func metaDetailsNeedsRepublish(','private static func metaDetailsStreamsChanged(',
        'private static func currentReadyStreamCount(','private static func libraryMetaDetailsUpdate(',
        'private static func nativeMetadataNavigationIsValid(',
        'private static func streamAddonStatusProjection(','private static func describeResourceError(',
        core.includes('private static func streamSetsEqual(')?'private static func streamSetsEqual(':'private static func streamSetSignature(',
        'private func assembleStreamGroups(','func streamAddonStates('].map(get);
    if(!members.at(-1).includes('metadataPresentation.acceptedStatus'))
        throw Error('Current getter must read the actual committed frame sidecar');
    const source='import Foundation\nimport CoreFoundation\nimport Combine\nimport os\n'
        +top.join('\n\n')+'\n'
        // This RAM owner has an explicit actor-owned publisher. Its conformance is actor-owned too;
        // that is not a typecheck or an isolation assertion about the mixed production CoreBridge.
        +'@MainActor final class CoreBridge: @MainActor ObservableObject {\n'
        +'    let objectWillChange = ObservableObjectPublisher()\n'
        +'    private lazy var metadataPresentation = MetadataPresentation(objectWillChange: objectWillChange)\n'
        +'    var metaDetails: CoreMetaDetails? { metadataPresentation.metaDetails }\n'
        +'    var streamsEpoch: Int { metadataPresentation.streamsEpoch }\n'
        +'    var metadataPublications=0, statusPublications=0, indexerStarts=0\n'
        +'    var names: [String:String] = [:]\n'
        +'    private var subscriptions: Set<AnyCancellable> = []\n'
        +'    init() {\n'
        +'        metadataPresentation.metaDetailsPublisher.dropFirst().sink { [weak self] _ in self?.metadataPublications += 1 }.store(in: &subscriptions)\n'
        +'        metadataPresentation.statusPublisher.dropFirst().sink { [weak self] _ in self?.statusPublications += 1 }.store(in: &subscriptions)\n'
        +'    }\n'
        +'    func addonNamesByBase()->[String:String] { names }\n'
        +'    func isTombstonedAddonBase(_ base:String,removed:Set<String>)->Bool { false }\n'
        +types.join('\n\n')+'\n'+nested.join('\n\n')+'\n'+negative+'\n'+members.join('\n\n')+'\n'
        +String.raw`
    // RAM composition only: these local-original closure stores prove NO source
    // receipt/Facade/Session/task/phase admission, decoder scheduling or indexer.
    func needs(_ next:CoreMetaDetails?)->Bool { Self.metaDetailsNeedsRepublish(current:metaDetails,next:next) }
    func streamsChange(_ next:CoreMetaDetails?)->Bool { Self.metaDetailsStreamsChanged(current:metaDetails,next:next) }
    func readyCount(_ group:[String:Any])->Int? { Self.currentReadyStreamCount(group) }
    func groups(streamID:String?=nil)->[CoreStreamSourceGroup] {
        guard let metaDetails else { return [] }
        return assembleStreamGroups(metaDetails,streamId:streamID)
    }
    func accept(_ details:CoreMetaDetails?) {
        let changed=Self.metaDetailsNeedsRepublish(current:metaDetails,next:details)
        guard metadataPresentation.commitFrame(details:details,status:nil,
            expectedProposal:metadataPresentation.proposal.metadata,isCurrent:{true},
            trustedStore:{ store in store(); return true }) else { return }
        if changed, details != nil { indexerStarts += 1 }
    }
    func acceptLibrary(_ details:CoreMetaDetails?) {
        guard let merged=Self.libraryMetaDetailsUpdate(current:metaDetails,next:details) else { return }
        _=metadataPresentation.commitOverlay(merged,expectedProposal:metadataPresentation.proposal.metadata,
            isCurrent:{true},trustedStore:{ store in store(); return true })
    }
    func acceptData(_ data:Data) throws {
        let details=try JSONDecoder().decode(CoreMetaDetails?.self,from:data)
        let status=try Self.streamAddonStatusProjection(data:data,details:details)
        let changed=Self.metaDetailsNeedsRepublish(current:metaDetails,next:details)
        guard metadataPresentation.commitFrame(details:details,status:status,
            expectedProposal:metadataPresentation.proposal.metadata,isCurrent:{true},
            trustedStore:{ store in store(); return true }) else { return }
        if changed, details != nil { indexerStarts += 1 }
    }
}
typealias AddonPublicationProbe = CoreBridge
`+'\n'+cases;
    return {source,receipts,productionTransformations:[],
        negativeControlTransformations:['rename exact owner class','remove exactly one post-willChange final-store veto'],
        fixtureOnly:['RAM CoreBridge storage/counters/name map','local-original accept/acceptData/acceptLibrary composition',
            'trusted-store refusal/current-flag scheduling is NOT real F/source authority',
            'exact immutable frame owner/cases; not original native pipeline/Facade/Session runtime']};
}
module.exports={exact,required,guardedPublication};
