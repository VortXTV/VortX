'use strict';

/*
 * Recovery-only source contract. This module inspects the current production
 * CoreBridge and VortxNativeCoreFacade text supplied by the caller. It does
 * not compile, execute, synthesize, or substitute any recovery fragment.
 *
 * exact must be a callback of the form:
 *   (source, marker, receipts, owner) -> exactSlice | null
 * An object with an equivalent .extract callback is also accepted. A missing
 * callback, source, marker, owner, or final method fails closed.
 */
function frameSourceContracts(core, facade, exact, receipts = []) {
    const failures = [];
    const checks = [];
    const slices = Object.create(null);
    const CORE_OWNER = 'app/SourcesShared/CoreBridge.swift';
    const FACADE_OWNER = 'app/SourcesShared/VortxNativeCoreFacade.swift';

    if (typeof core !== 'string' || core.length === 0) {
        failures.push('core production source text is required');
    }
    if (typeof facade !== 'string' || facade.length === 0) {
        failures.push('facade production source text is required');
    }
    if (!Array.isArray(receipts)) {
        failures.push('receipts must be an array when supplied');
    }

    const extractor = typeof exact === 'function'
        ? exact
        : exact && typeof exact.extract === 'function'
            ? exact.extract.bind(exact)
            : null;
    if (!extractor) {
        failures.push('an exact(source, marker, receipts, owner) extractor is required');
    }
    if (failures.length > 0) {
        return {
            name: 'frame-source-contracts',
            ok: false,
            checks,
            failures,
            prerequisites: [
                'current CoreBridge source text',
                'current VortxNativeCoreFacade source text',
                'exact(source, marker, receipts, owner)'
            ],
            receiptCount: Array.isArray(receipts) ? receipts.length : 0,
            runtimeProof: false,
            sdkProof: false,
            pipelineProof: false
        };
    }

    function extract(label, source, marker, owner) {
        let value;
        try {
            value = extractor(source, marker, receipts, owner);
        } catch {
            failures.push(label + ': exact extractor threw');
            return null;
        }
        const text = typeof value === 'string'
            ? value
            : value && typeof value.text === 'string'
                ? value.text
                : value && typeof value.source === 'string'
                    ? value.source
                    : null;
        if (typeof text !== 'string' || text.length === 0) {
            failures.push(label + ': exact slice missing');
            return null;
        }
        if (!text.includes(marker)) {
            failures.push(label + ': exact slice omitted its start marker');
            return null;
        }
        if (owner !== CORE_OWNER && owner !== FACADE_OWNER) {
            failures.push(label + ': unsupported source owner');
            return null;
        }
        slices[label] = text;
        return text;
    }

    function containsEveryToken(text, tokens) {
        return typeof text === 'string'
            && tokens.every((token) => typeof token === 'string'
                && token.length > 0
                && text.includes(token));
    }

    function removeAllOccurrences(text, token) {
        if (typeof text !== 'string' || typeof token !== 'string' || token.length === 0) {
            return text;
        }
        return text.split(token).join('');
    }

    // This is a local assertion window over an already exact-extracted method,
    // not another source extractor or an end-marker boundary.
    function suffixFrom(text, marker) {
        if (typeof text !== 'string' || typeof marker !== 'string' || marker.length === 0) {
            return null;
        }
        const start = text.indexOf(marker);
        return start < 0 ? null : text.slice(start);
    }

    function evaluate(name, text, required, forbidden, order) {
        const requiredTokens = Array.from(new Set(required));
        const forbiddenTokens = Array.from(new Set(forbidden));
        const missing = !text
            ? ['exact slice unavailable']
            : requiredTokens.filter((token) => !text.includes(token));
        const foundForbidden = text
            ? forbiddenTokens.filter((token) => text.includes(token))
            : [];
        const removalNegatives = text
            ? requiredTokens.filter((token) => containsEveryToken(
                removeAllOccurrences(text, token), requiredTokens))
            : [];
        const orderFailures = [];
        let cursor = -1;
        for (const token of order) {
            const next = text ? text.indexOf(token, cursor + 1) : -1;
            if (next < 0) {
                orderFailures.push(token);
            } else {
                cursor = next;
            }
        }
        const ok = missing.length === 0
            && foundForbidden.length === 0
            && removalNegatives.length === 0
            && orderFailures.length === 0;
        checks.push({
            name,
            ok,
            missing,
            forbidden: foundForbidden,
            removalNegatives,
            order: orderFailures
        });
        if (!ok) {
            failures.push(name + ': ' + JSON.stringify({
                missing,
                forbidden: foundForbidden,
                removalNegatives,
                order: orderFailures
            }));
        }
        return ok;
    }

    const frameAdmission = extract(
        'core.NativeMetadataFrameAdmission',
        core,
        'private enum NativeMetadataFrameAdmission',
        CORE_OWNER
    );
    const frameCommit = extract(
        'core.MetadataPresentation.commit',
        core,
        'private func commit(_ mutation: Mutation',
        CORE_OWNER
    );
    const ownedFrameCommit = extract(
        'core.commitOwnedMetadataFrame',
        core,
        '@MainActor @discardableResult\n    private func commitOwnedMetadataFrame(',
        CORE_OWNER
    );
    const finalStore = extract(
        'facade.storeOriginalMetadataPresentationFrame',
        facade,
        'func storeOriginalMetadataPresentationFrame(',
        FACADE_OWNER
    );
    const hostFinalStore = extract(
        'facade.storeOriginalMetadataHostFrame',
        facade,
        'func storeOriginalMetadataHostFrame(',
        FACADE_OWNER
    );

    evaluate(
        'immutable frame admission routes source, host, and local stores',
        frameAdmission,
        [
            'case let .source(facade, change, selection, libraryOverlay)',
            'storeOriginalMetadataPresentationFrame(change, selection: selection',
            'case let .host(facade, selection)',
            'storeOriginalMetadataHostFrame(selection: selection',
            'case .localOriginal',
            'store()'
        ],
        ['metadataSnapshot(', 'stateData'],
        [
            'case let .source',
            'storeOriginalMetadataPresentationFrame',
            'case let .host',
            'storeOriginalMetadataHostFrame',
            'case .localOriginal'
        ]
    );
    evaluate(
        'immutable frame commit prepares before one trusted final store',
        frameCommit,
        [
            'let previous = backing',
            'defer { withExtendedLifetime(previous) {} }',
            'let prepared = NativeMetadataFrameBox',
            'let admitted = trustedStore { self.backing = prepared }',
            'guard admitted else',
            'if backing === prepared',
            'values.send(prepared)'
        ],
        [
            'backing = changed.frame',
            'self.backing = changed.frame',
            'Task.detached',
            'JSONEncoder',
            'JSONDecoder',
            'metadataSnapshot(',
            'stateData'
        ],
        [
            'let previous = backing',
            'let prepared = NativeMetadataFrameBox',
            'let admitted = trustedStore { self.backing = prepared }',
            'guard admitted else',
            'values.send(prepared)'
        ]
    );
    evaluate(
        'owned frame commit uses the real source admission seam',
        ownedFrameCommit,
        [
            'guard case .source(_, _, _, false) = finalAdmission else { return false }',
            'metadataPresentation.commitFrame',
            'finalAdmission.storePreparedFrame($0)'
        ],
        [
            'commitNativeMetadata(',
            'metaDetails =',
            'streamsEpoch &+='
        ],
        [
            'guard case .source',
            'metadataPresentation.commitFrame',
            'finalAdmission.storePreparedFrame'
        ]
    );
    evaluate(
        'facade final store linearizes source gates before immutable swap',
        finalStore,
        [
            'lock.lock()',
            'defer { lock.unlock() }',
            'guard change.sourceID == sourceID',
            'metadataSelectionIsCurrent(selection)',
            'let joined = metadataSelection(for: change',
            'joined == selection',
            'change.fields.contains("meta_details")',
            'acceptsChange(change, field: "meta_details", settlingResource: true)',
            'change.fields.contains("library")',
            'acceptsChange(change, field: "library")',
            'acceptsChange(change, field: "meta_details", settlingResource: false)',
            'storePreparedFrame()',
            'return true'
        ],
        [
            'objectWillChange.send',
            '.send(',
            'Task',
            'JSONEncoder',
            'JSONDecoder',
            'cancel',
            'metadataSnapshot(',
            'stateData',
            'captureMetadataSelection'
        ],
        [
            'lock.lock()',
            'guard change.sourceID == sourceID',
            'metadataSelectionIsCurrent(selection)',
            'let joined = metadataSelection(for: change',
            'joined == selection',
            'change.fields.contains("library")',
            'acceptsChange(change, field: "library")',
            'acceptsChange(change, field: "meta_details", settlingResource: false)',
            'change.fields.contains("meta_details")',
            'acceptsChange(change, field: "meta_details", settlingResource: true)',
            'storePreparedFrame()'
        ]
    );
    evaluate(
        'facade host final store linearizes current selection before immutable swap',
        hostFinalStore,
        [
            'lock.lock()',
            'defer { lock.unlock() }',
            'guard metadataSelectionIsCurrent(selection) else { return false }',
            'storePreparedFrame()',
            'return true'
        ],
        [
            'objectWillChange.send',
            '.send(',
            'Task',
            'JSONEncoder',
            'JSONDecoder',
            'cancel',
            'metadataSnapshot(',
            'stateData',
            'captureMetadataSelection',
            'sourceID',
            'acceptsChange('
        ],
        [
            'lock.lock()',
            'metadataSelectionIsCurrent(selection)',
            'storePreparedFrame()',
            'return true'
        ]
    );

    const operationStruct = extract(
        'core.NativeMetadataOperation',
        core,
        'private struct NativeMetadataOperation',
        CORE_OWNER
    );
    const operationCurrent = extract(
        'core.nativeMetadataOperationIsCurrent',
        core,
        '@MainActor private func nativeMetadataOperationIsCurrent(',
        CORE_OWNER
    );
    const schedule = extract(
        'core.scheduleOwnedMetadata',
        core,
        '@MainActor private func scheduleOwnedMetadata(',
        CORE_OWNER
    );
    const publish = extract(
        'core.publishOwnedMetadata',
        core,
        '@MainActor private func publishOwnedMetadata(',
        CORE_OWNER
    );
    const receive = extract(
        'core.receiveOwnedMetadata',
        core,
        '@MainActor private func receiveOwnedMetadata(',
        CORE_OWNER
    );

    evaluate(
        'operation retains original task selection source receipt',
        operationStruct,
        [
            'let intent: NativeMetadataIntent',
            'let selection: VortxNativeCoreFacade.MetadataSelectionReceipt',
            'let source: VortxNativeCoreFacade.ChangeReceipt',
            'let decode: UUID'
        ],
        ['metadataSnapshot(', 'stateData', 'captureMetadataSelection'],
        []
    );
    evaluate(
        'operation current gate validates original source receipt',
        operationCurrent,
        [
            'activeDecode == operation.decode',
            'ownedMetadataSelection == operation.selection',
            'operation.source.fields.contains("meta_details")',
            'facade.acceptsChange(operation.source',
            'facade.metadataSelection(for: operation.source',
            '== operation.selection'
        ],
        ['metadataSnapshot(', 'stateData', 'captureMetadataSelection'],
        [
            'nativeMetadataIntentIsCurrent(operation.intent)',
            'activeDecode == operation.decode',
            'ownedMetadataSelection == operation.selection',
            'facade.acceptsChange(operation.source'
        ]
    );
    evaluate(
        'received metadata retains original producer and source receipt',
        receive,
        [
            'nativeCallbackOriginIsCurrent(origin)',
            'event.producer === origin.producer',
            'case .changed(_, let change?) = event.kind',
            'let intent = ownedMetadataIntent',
            'nativeMetadataIntentIsCurrent(intent)',
            'intent.owner.facade === event.producer',
            'intent.owner.callbackInstallation == origin.installation',
            'intent.owner.credential == origin.credential',
            'change.sourceID == event.sourceID',
            'let resource = change.fields.contains("meta_details")',
            'guard resource || (change.fields.contains("library") && !origin.playerWasActive)',
            'let selection = event.producer.metadataSelection(for: change',
            'selection == ownedMetadataSelection',
            'let value = change.values["meta_details"]',
            'scheduleOwnedMetadata(value, intent: intent, selection: selection, source: change'
        ],
        [
            'captureMetadataSelection(',
            'metadataSnapshot(',
            'stateData('
        ],
        [
            'nativeCallbackOriginIsCurrent(origin)',
            'event.producer === origin.producer',
            'case .changed(_, let change?) = event.kind',
            'let intent = ownedMetadataIntent',
            'nativeMetadataIntentIsCurrent(intent)',
            'intent.owner.facade === event.producer',
            'intent.owner.callbackInstallation == origin.installation',
            'intent.owner.credential == origin.credential',
            'change.sourceID == event.sourceID',
            'let resource = change.fields.contains("meta_details")',
            'guard resource || (change.fields.contains("library") && !origin.playerWasActive)',
            'let selection = event.producer.metadataSelection(for: change',
            'selection == ownedMetadataSelection',
            'let value = change.values["meta_details"]',
            'scheduleOwnedMetadata(value, intent: intent, selection: selection, source: change'
        ]
    );
    evaluate(
        'scheduled worker carries operation receipt through publish',
        schedule,
        [
            'let decode = UUID()',
            'let operation = NativeMetadataOperation',
            'selection: selection',
            'source: source',
            'decode: decode',
            'previous?.cancel()',
            'guard nativeMetadataOperationIsCurrent(operation)',
            'let task = Task.detached',
            'let data = try JSONEncoder().encode(value)',
            'let details = try JSONDecoder().decode(CoreMetaDetails?.self, from: data)',
            'let status = try Self.streamAddonStatusProjection(data: data, details: details)',
            'await receiver.publish(.init(details: details, status: status), operation: operation)'
        ],
        ['metadataSnapshot(', 'stateData', 'captureMetadataSelection'],
        [
            'let decode = UUID()',
            'let operation = NativeMetadataOperation',
            'source: source',
            'previous?.cancel()',
            'let task = Task.detached',
            'let data = try JSONEncoder().encode(value)',
            'let details = try JSONDecoder().decode(CoreMetaDetails?.self, from: data)',
            'let status = try Self.streamAddonStatusProjection(data: data, details: details)',
            'await receiver.publish'
        ]
    );
    evaluate(
        'published frame has no direct legacy setter or epoch writer',
        publish,
        [
            'let owns: @MainActor @Sendable () -> Bool = { self.nativeMetadataOperationIsCurrent(operation) }',
            'guard owns() else { return }',
            'let proposal = captureNativeMetadataPresentationProposal()',
            'NativeMetadataFrameAdmission.source',
            'if operation.kind == .libraryOverlay',
            'guard let merged = Self.libraryMetaDetailsUpdate(current: metaDetails, next: sample.details) else { return }',
            'commitOwnedMetadataOverlay(merged, expectedProposal: proposal.metadata',
            'isCurrent: owns, finalAdmission: sourceAdmission',
            'return // no sources/status/epoch/phase settlement from a library marker',
            'let details = sample.details',
            'guard commitOwnedMetadataFrame(details: details, status: sample.status,',
            'expectedProposal: proposal.metadata, isCurrent: owns,',
            'finalAdmission: sourceAdmission), owns() else { return }',
            'if let details',
            'startNZBIndexerSearchIfNeeded',
            'replayPendingEpisodeWatched',
            'advanceOwnedMetadataPhase'
        ],
        [
            'metaDetails =',
            'streamsEpoch &+=',
            'objectWillChange.send',
            'commitNativeMetadata(',
            'metadataSnapshot(',
            'stateData'
        ],
        [
            'let owns: @MainActor @Sendable () -> Bool = { self.nativeMetadataOperationIsCurrent(operation) }',
            'NativeMetadataFrameAdmission.source',
            'if operation.kind == .libraryOverlay',
            'guard let merged = Self.libraryMetaDetailsUpdate(current: metaDetails, next: sample.details) else { return }',
            'commitOwnedMetadataOverlay(merged, expectedProposal: proposal.metadata',
            'isCurrent: owns, finalAdmission: sourceAdmission',
            'return // no sources/status/epoch/phase settlement from a library marker',
            'let details = sample.details',
            'guard commitOwnedMetadataFrame(details: details, status: sample.status,',
            'expectedProposal: proposal.metadata, isCurrent: owns,',
            'finalAdmission: sourceAdmission), owns() else { return }',
            'if let details',
            'startNZBIndexerSearchIfNeeded',
            'replayPendingEpisodeWatched',
            'advanceOwnedMetadataPhase'
        ]
    );

    const pendingClear = extract(
        'core.clearNativeMetadataForPendingEntry',
        core,
        '@MainActor @discardableResult\n    private func clearNativeMetadataForPendingEntry(',
        CORE_OWNER
    );
    const directStart = extract(
        'core.startNativeMetadataDirectEntry',
        core,
        '@MainActor @discardableResult\n    private func startNativeMetadataDirectEntry(',
        CORE_OWNER
    );
    const directPrepare = extract(
        'core.prepareNativeMetadataDirectEntry',
        core,
        'private func prepareNativeMetadataDirectEntry(action: VortxJSON,',
        CORE_OWNER
    );

    evaluate(
        'pending no-owner clear remains local and preserves pending M',
        pendingClear,
        [
            'guard entry.owner == nil, owns() else { return false }',
            'ownedMetadataHostRequestIsCurrent(entry.host)',
            'publicationEpochMatches(entry.publication)',
            'nativeMetadataAdmissionFence.captureInstallation() == entry.installation',
            'let hadDetails = metaDetails != nil',
            'commitOwnedMetadataClear(bumpStreams: hadDetails, preservingClear: nil',
            'finalAdmission: .localOriginal',
            'return owns()'
        ],
        [
            'commitNativeMetadata(',
            'finalAdmission: .source',
            'finalAdmission: .host',
            'dispatchMetadata(',
            'startOwnedMetadataIntent(',
            'storeOriginalMetadataPresentationFrame('
        ],
        [
            'guard entry.owner == nil, owns()',
            'let hadDetails = metaDetails != nil',
            'commitOwnedMetadataClear',
            'finalAdmission: .localOriginal',
            'return owns()'
        ]
    );
    evaluate(
        'direct metadata preflight validates before retirement and host mutation',
        directPrepare,
        [
            'guard Self.nativeMetadataNavigationIsValid(action) else { return nil }',
            'metadataPresentation.retireClearAuthority()',
            'let scope = originalScope ?? NativeResourceIntentScope(',
            'let owner = captureNativeMetadataOwner()',
            'let publication = capturePublicationToken()',
            'let installation = nativeMetadataAdmissionFence.captureInstallation()',
            'let identity = UUID()',
            'ownedMetadataHostIdentity = identity',
            'prepareOwnedMetadataRequest(action: action, scope: scope',
            'let proposals = captureNativeMetadataPresentationProposal()',
            'let cancelOwned = detachOwnedMetadataWork()',
            'metaDetailsWork = nil'
        ],
        [
            'captureMetadataSelection',
            'metadataSnapshot(',
            'stateData',
            'dispatchMetadata('
        ],
        [
            'guard Self.nativeMetadataNavigationIsValid(action) else { return nil }',
            'metadataPresentation.retireClearAuthority()',
            'let scope = originalScope ?? NativeResourceIntentScope(',
            'let owner = captureNativeMetadataOwner()',
            'let publication = capturePublicationToken()',
            'let installation = nativeMetadataAdmissionFence.captureInstallation()',
            'let identity = UUID()',
            'ownedMetadataHostIdentity = identity',
            'prepareOwnedMetadataRequest(action: action, scope: scope',
            'let proposals = captureNativeMetadataPresentationProposal()',
            'let cancelOwned = detachOwnedMetadataWork()',
            'metaDetailsWork = nil'
        ]
    );
    evaluate(
        'direct entry fails closed through no-owner pending clear',
        directStart,
        [
            'guard let owner = entry.owner else',
            '_ = clearNativeMetadataForPendingEntry(entry)',
            'return false'
        ],
        ['captureNativeMetadataOwner()', 'metadataSnapshot(', 'stateData'],
        [
            'guard let owner = entry.owner else',
            'clearNativeMetadataForPendingEntry(entry)',
            'return false'
        ]
    );

    const validator = extract(
        'core.nativeMetadataNavigationIsValid',
        core,
        'private static func nativeMetadataNavigationIsValid(',
        CORE_OWNER
    );
    const hostDispatch = extract(
        'core.dispatchOwnedMetadataHostAction',
        core,
        '@MainActor private func dispatchOwnedMetadataHostAction(',
        CORE_OWNER
    );

    evaluate(
        'malformed metadata validator is pure and ordered',
        validator,
        [
            'if action["action"] == .string("Unload") { return true }',
            'guard action["action"] == .string("Load")',
            'action["args"]?["model"] == .string("MetaDetails")',
            'case .string = action["args"]?["args"]?["metaPath"]?["id"]',
            'return false'
        ],
        [
            'VXProbe.log',
            'NSLog',
            'metadataPresentation',
            'ownedMetadataHostIdentity',
            'prepareOwnedMetadataRequest',
            'dispatchMetadata(',
            'CredentialScopeRegistry'
        ],
        [
            'if action["action"] == .string("Unload")',
            'guard action["action"] == .string("Load")',
            'action["args"]?["model"]',
            'case .string = action["args"]?["args"]?["metaPath"]?["id"]'
        ]
    );
    evaluate(
        'malformed dispatch narrates only after validation and before mutation',
        hostDispatch,
        [
            'let value = try? JSONDecoder().decode(VortxJSON.self, from: data)',
            'guard Self.nativeMetadataNavigationIsValid(value) else',
            'VXProbe.log("engine", "dispatch',
            'NSLog("[CoreBridge] native action rejected: %@", "invalid_meta_path")',
            'let scope = NativeResourceIntentScope',
            'let owner = captureNativeMetadataOwner(), identity = UUID()',
            'metadataPresentation.retireClearAuthority()',
            'ownedMetadataHostIdentity = identity',
            'prepareOwnedMetadataRequest(action: value, scope: scope, identity: identity)',
            'let cancel = detachOwnedMetadataWork()',
            'let oldLegacy = metaDetailsWork; metaDetailsWork = nil',
            'appleCWMetaRefreshRequest = nil; appleCWMetaRefreshReceipt = nil; appleCWMetaRefreshDetails = nil',
            'refindRequest = nil; refindGeneration &+= 1',
            'cancel(); oldLegacy?.cancel()',
            'guard ownedMetadataHostRequestIsCurrent(host) else { return false }',
            'beforeDispatch?()',
            'guard ownedMetadataHostRequestIsCurrent(host), let owner else { return false }',
            'return startOwnedMetadataIntent(host, owner: owner, refind: refindGeneration)'
        ],
        ['captureMetadataSelection', 'metadataSnapshot(', 'stateData'],
        [
            'guard Self.nativeMetadataNavigationIsValid(value) else',
            'VXProbe.log("engine", "dispatch',
            'NSLog("[CoreBridge] native action rejected: %@", "invalid_meta_path")',
            'let scope = NativeResourceIntentScope',
            'let owner = captureNativeMetadataOwner(), identity = UUID()',
            'metadataPresentation.retireClearAuthority()',
            'ownedMetadataHostIdentity = identity',
            'prepareOwnedMetadataRequest(action: value, scope: scope, identity: identity)',
            'let cancel = detachOwnedMetadataWork()',
            'let oldLegacy = metaDetailsWork; metaDetailsWork = nil',
            'appleCWMetaRefreshRequest = nil; appleCWMetaRefreshReceipt = nil; appleCWMetaRefreshDetails = nil',
            'refindRequest = nil; refindGeneration &+= 1',
            'cancel(); oldLegacy?.cancel()',
            'guard ownedMetadataHostRequestIsCurrent(host) else { return false }',
            'beforeDispatch?()',
            'guard ownedMetadataHostRequestIsCurrent(host), let owner else { return false }',
            'return startOwnedMetadataIntent(host, owner: owner, refind: refindGeneration)'
        ]
    );

    const selectionLifecycle = extract(
        'core.nativeMetadataSelectionLifecycleIsCurrent',
        core,
        '@MainActor private func nativeMetadataSelectionLifecycleIsCurrent(',
        CORE_OWNER
    );
    const directStartForIndexer = directStart;
    const nzb = extract(
        'core.startNZBIndexerSearchIfNeeded',
        core,
        '@MainActor private func startNZBIndexerSearchIfNeeded(',
        CORE_OWNER
    );
    const nzbConfiguration = extract(
        'core.nzbIndexerConfigurationDidChange',
        core,
        '@MainActor func nzbIndexerConfigurationDidChange()',
        CORE_OWNER
    );
    const nzbPostEpoch = suffixFrom(
        nzb,
        'advanceNativeStreamsEpoch(expectedProposal: proposal.streams'
    );

    evaluate(
        'stable selection lifecycle retains original host and producing task',
        selectionLifecycle,
        [
            'ownedMetadataIntent?.identity == intent.identity',
            'ownedMetadataIntent?.host.request == intent.host.request',
            'ownedMetadataHostRequestIsCurrent(intent.host)',
            'nativeMetadataOwnerIsCurrent(intent.owner)',
            'ownedMetadataSelection == selection',
            'intent.owner.facade.metadataSelectionIsCurrent(selection)'
        ],
        [
            'appleCWMetaRefreshRequest',
            'refindGeneration',
            'nzbIndexerGeneration',
            'nativeMetadataIntentIsCurrent',
            'ownedMetadataDecode',
            'ownedMetadataOverlayDecode',
            '.refresh',
            '.refind',
            'metadataSnapshot(',
            'stateData'
        ],
        []
    );
    evaluate(
        'equal-seed path relaunches NZB work after invalidation',
        publish,
        [
            'commitOwnedMetadataFrame',
            'if let details',
            'startNZBIndexerSearchIfNeeded(details: details',
            'nativeMetadataSelectionLifecycleIsCurrent(operation.intent, selection: operation.selection)'
        ],
        ['if !metadataChanged', 'guard !metadataChanged'],
        [
            'commitOwnedMetadataFrame',
            'if let details',
            'startNZBIndexerSearchIfNeeded(details: details',
            'nativeMetadataSelectionLifecycleIsCurrent(operation.intent, selection: operation.selection)'
        ]
    );
    evaluate(
        'NZB post-epoch task handoff retains generation cleanup without isCurrent guard',
        nzbPostEpoch,
        [
            'advanceNativeStreamsEpoch(expectedProposal: proposal.streams',
            'guard ownsIndexer() else',
            'if nzbIndexerGeneration == generation, activeNZBIndexerKey == key',
            'activeNZBIndexerKey = nil; activeNZBIndexerCount = 0',
            'nzbIndexerTasks[key] = Task'
        ],
        [
            'guard isCurrent',
            'guard isCurrent() else'
        ],
        [
            'advanceNativeStreamsEpoch(expectedProposal: proposal.streams',
            'guard ownsIndexer() else',
            'if nzbIndexerGeneration == generation, activeNZBIndexerKey == key',
            'activeNZBIndexerKey = nil; activeNZBIndexerCount = 0',
            'nzbIndexerTasks[key] = Task'
        ]
    );
    evaluate(
        'direct same-route start invalidates old NZB result before relaunch',
        directStartForIndexer,
        [
            'if invalidateIndexer',
            'invalidateNZBIndexerResults()',
            'return startOwnedMetadataIntent(entry.host, owner: owner'
        ],
        ['metadataSnapshot(', 'stateData'],
        [
            'if invalidateIndexer',
            'invalidateNZBIndexerResults()',
            'return startOwnedMetadataIntent(entry.host, owner: owner'
        ]
    );
    evaluate(
        'NZB work keys and completion retain stable lifecycle',
        nzb,
        [
            'let key = NZBIndexerResultKey',
            'revision: document.revision',
            'titleID: meta.id',
            'streamID: streamID',
            'guard !nzbIndexerTerminal.contains(key), nzbIndexerResults[key] == nil',
            'let beforeCancellation = nzbIndexerGeneration',
            'nzbIndexerGeneration &+= 1',
            'let generation = nzbIndexerGeneration',
            'lifecycleIsCurrent()',
            'nzbIndexerTasks[key] = Task',
            'nzbIndexerResults[key] =',
            'nzbIndexerTerminal.insert(key)',
            'advanceNativeStreamsEpoch'
        ],
        [
            'metadataSnapshot(',
            'stateData',
            'captureMetadataSelection',
            'CredentialScopeRegistry.shared.capture()'
        ],
        [
            'let key = NZBIndexerResultKey',
            'let beforeCancellation = nzbIndexerGeneration',
            'nzbIndexerGeneration &+= 1',
            'let generation = nzbIndexerGeneration',
            'nzbIndexerTasks[key] = Task',
            'nzbIndexerResults[key] =',
            'nzbIndexerTerminal.insert(key)',
            'advanceNativeStreamsEpoch'
        ]
    );
    evaluate(
        'NZB configuration change uses stable helper and admitted final stores',
        nzbConfiguration,
        [
            'let originalIntent = ownedMetadataIntent, selection = ownedMetadataSelection',
            'let host = ownedMetadataHostIdentity, publication = capturePublicationToken()',
            'let installation = nativeMetadataAdmissionFence.captureInstallation()',
            'let ownsHost: @MainActor @Sendable () -> Bool = { [weak self] in',
            'self.ownedMetadataHostIdentity == host && self.publicationEpochMatches(publication)',
            'self.nativeMetadataAdmissionFence.captureInstallation() == installation',
            'let cancel = detachNZBIndexerResults()',
            'cancel()',
            'guard ownsHost() else { return }',
            'isCurrent: ownsHost, finalAdmission: .localOriginal',
            'nativeMetadataSelectionLifecycleIsCurrent(intent, selection: selection)',
            'startNZBIndexerSearchIfNeeded(details: details, isCurrent: owns, lifecycleIsCurrent: owns',
            'finalAdmission: .host(facade: intent.owner.facade, selection: selection)'
        ],
        [
            'metadataSnapshot(',
            'stateData',
            'captureMetadataSelection',
            'nativeMetadataIntentIsCurrent'
        ],
        [
            'let originalIntent = ownedMetadataIntent, selection = ownedMetadataSelection',
            'let host = ownedMetadataHostIdentity, publication = capturePublicationToken()',
            'let installation = nativeMetadataAdmissionFence.captureInstallation()',
            'let ownsHost: @MainActor @Sendable () -> Bool = { [weak self] in',
            'self.ownedMetadataHostIdentity == host && self.publicationEpochMatches(publication)',
            'self.nativeMetadataAdmissionFence.captureInstallation() == installation',
            'let cancel = detachNZBIndexerResults()',
            'cancel()',
            'guard ownsHost() else { return }',
            'isCurrent: ownsHost, finalAdmission: .localOriginal',
            'nativeMetadataSelectionLifecycleIsCurrent(intent, selection: selection)',
            'startNZBIndexerSearchIfNeeded(details: details, isCurrent: owns, lifecycleIsCurrent: owns',
            'finalAdmission: .host(facade: intent.owner.facade, selection: selection)'
        ]
    );

    return {
        name: 'frame-source-contracts',
        ok: failures.length === 0,
        checks,
        failures,
        extracted: Object.keys(slices),
        receiptCount: receipts.length,
        prerequisites: [
            '02b owner methods are present in current CoreBridge source',
            '01c final-store and source-gate methods are present in current facade source',
            '07/07b direct preflight, direct routes, and guarded pending clear are present',
            '08/09 receive/operation, validator, NZB lifecycle, and configuration rebind methods are present',
            'the exact extractor returns real production slices'
        ],
        runtimeProof: false,
        sdkProof: false,
        pipelineProof: false
    };
}

module.exports = frameSourceContracts;
module.exports.frameSourceContracts = frameSourceContracts;
