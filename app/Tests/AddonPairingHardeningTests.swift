// Focused QR2 hardening contracts. Compile with:
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/AddonPairingProtocol.swift \
//     app/SourcesShared/AddonPairingReducer.swift \
//     app/SourcesShared/AddonPairingClient.swift \
//     app/SourcesShared/AddonURLGuard.swift \
//     app/SourcesShared/VortXEdgeAuth.swift \
//     app/Tests/AddonPairingHardeningTests.swift \
//     -o /tmp/addon-pairing-hardening-tests && /tmp/addon-pairing-hardening-tests

import Foundation

@main
struct AddonPairingHardeningTests {
    nonisolated(unsafe) private static var failures = 0

    static func main() async {
        durableDeliveryReplayIsIdempotent()
        wrongSessionIsRejected()
        invalidClaimCannotStartInstall()
        staleAttemptIsRejected()
        transactionalReplacementRejectsStaleWork()
        closedSessionDrainsBeforeRelease()
        restartUsesDurableDeliveryIdentity()
        strictRelayValuesFailClosed()
        await hostileRedirectIsRevalidated()
        await userinfoIsRejected()
        await httpsSchemeIsRequiredByFetchGuard()
        streamedBodyCapIsBounded()
        protocolResponseCapIsBounded()
        strictManifestURLContractIsEnforced()
        mutationResponsesAreBoundToState()
        bodySignatureBindsAcknowledgement()
        pathlessProtocolFixtureIsExact()
        ackCommitsOnlyAfterNetworkSuccessAndRequeues()
        retryableFailureRetainsTheSession()
        resumeRequeuesCanceledDurableWork()
        resumeRequeuesPendingAcknowledgement()
        reopenRebasesPendingAcknowledgementAndFencesStaleAuthority()
        releaseTombstoneResponseIsStrict()
        claimAndAckFailuresUseDistinctPhases()
        foreignClaimPollRebasesBeforeRecovery()
        manualRetryUsesServerClaimTupleAndDrains()
        manualRetryWaitsForLiveAckMutation()
        terminalDuplicateClaimLossRebasesWithoutRow()
        terminalDuplicateForeignClaimReopenDrains()
        terminalDuplicateReplacementRebasesByDeliveryID()
        terminalDuplicateFailedForeignClaimDrains()
        terminalDuplicateStaleRevisionCannotOverwrite()
        terminalDuplicateHighWaterReentersNormalIdentity()
        terminalPreviewOutcomesClaimBeforeAck()
        initialPreviewClaimFailureAtZeroRequeues()
        lateResolveCompletionsAreFencedAcrossReplacement()
        staleGenerationPollConvergesToCurrentAuthority()
        closedReopenPollConvergesThroughRelease()
        lateLifecycleResultsAfterStopAreFenced()
        lateClaimCompletionAfterStopIsFenced()

        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func expect(_ condition: Bool, _ name: String) {
        if condition {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    private static func delivery(
        id: String = "delivery-1",
        token: String = "session-1",
        revision: Int = 7,
        deliveryRevision: Int = 0,
        retryable: Bool = false,
        status: AddonPairingReducer.DeliveryStatus = .pending
    ) -> AddonPairingReducer.Delivery {
        AddonPairingReducer.Delivery(
            id: id,
            url: "https://addon.example/manifest.json",
            identity: "https://addon.example/manifest.json",
            sessionToken: token,
            revision: revision,
            status: status,
            deliveryRevision: deliveryRevision,
            retryable: retryable
        )
    }

    private static func normalize(_ raw: String) -> String? {
        canonicalAddonIdentity(raw)
    }

    private static func reduceDurableResolved(
        _ state: inout AddonPairingReducer.State,
        rowID: String,
        outcome: AddonPairingReducer.ResolveOutcome
    ) -> [AddonPairingReducer.Effect] {
        guard let row = state.rows.first(where: { $0.id == rowID }) else { return [] }
        let ticket = AddonPairingReducer.ResolveTicket(
            rowID: row.id,
            revision: row.revision,
            deliveryRevision: row.deliveryRevision,
            identity: row.identity
        )
        return AddonPairingReducer.reduce(
            &state,
            .resolvedDurable(ticket: ticket, outcome: outcome),
            normalize: normalize
        )
    }

    private static func durableDeliveryReplayIsIdempotent() {
        var state = AddonPairingReducer.State()
        let first = delivery()
        let initial = AddonPairingReducer.reduce(
            &state,
            .deliveries([first], sessionToken: first.sessionToken, liveToken: first.sessionToken, revision: first.revision),
            normalize: normalize
        )
        expect(initial.contains(where: { if case let .resolveDurable(ticket, url) = $0 {
                   return ticket.rowID == first.id && ticket.revision == first.revision &&
                       ticket.deliveryRevision == first.deliveryRevision &&
                       ticket.identity == first.identity && url == first.url
               }; return false }),
               "durable delivery: first poll resolves once")

        let install = reduceDurableResolved(&state, rowID: first.id, outcome: .ready(name: "Example"))
        expect(install == [.claim(deliveryID: first.id, token: first.sessionToken,
                                  deliveryRevision: first.deliveryRevision,
                                  authoritySession: first.sessionToken, authorityGeneration: 0)],
               "durable delivery: ready claims a server-fenced attempt before installing")
        let claimed = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: first.id, authoritySession: first.sessionToken, authorityGeneration: 0,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        expect(claimed == [.installAttempt(rowId: first.id, url: first.url, attempt: 1)],
               "durable delivery: a successful claim starts install attempt 1")
        let replayResolve = reduceDurableResolved(&state, rowID: first.id, outcome: .ready(name: "Replay"))
        expect(replayResolve.isEmpty && state.rows[0].attempt == 1,
               "hostile replay: a late preview cannot rewind or start another attempt")
        _ = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: first.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )

        let replay = AddonPairingReducer.reduce(
            &state,
            .deliveries([first], sessionToken: first.sessionToken, liveToken: first.sessionToken, revision: first.revision),
            normalize: normalize
        )
        expect(replay.isEmpty && state.rows.count == 1 && state.rows[0].state == .installed,
               "hostile replay: same durable id cannot add or install a second row")
    }

    private static func wrongSessionIsRejected() {
        var state = AddonPairingReducer.State()
        let foreign = delivery(token: "foreign")
        let effects = AddonPairingReducer.reduce(
            &state,
            .deliveries([foreign], sessionToken: foreign.sessionToken, liveToken: "live-session", revision: 7),
            normalize: normalize
        )
        expect(effects.isEmpty && state.rows.isEmpty,
               "wrong session: foreign delivery creates no row or effect")
    }

    private static func staleAttemptIsRejected() {
        var state = AddonPairingReducer.State()
        let d = delivery()
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: d.sessionToken, authorityGeneration: 0,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let stale = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 0, outcome: .failed("stale")),
            normalize: normalize
        )
        expect(stale.isEmpty && state.rows[0].state == .installing,
               "stale attempt: an old completion cannot change the active install")

        _ = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        let duplicate = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        expect(duplicate.isEmpty && state.rows[0].state == .installed,
               "stale attempt: a duplicate completion is ignored after confirmation")
    }

    private static func invalidClaimCannotStartInstall() {
        var state = AddonPairingReducer.State()
        let d = delivery(token: "invalid-claim")
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        let invalid = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: d.sessionToken, authorityGeneration: 0,
                           attempt: 0, deliveryRevision: 0, success: true),
            normalize: normalize
        )
        expect(invalid.isEmpty && state.rows[0].state == .ready && state.rows[0].attempt == 0,
               "claim: an unconfirmed zero-attempt result cannot start installation")
    }

    private static func transactionalReplacementRejectsStaleWork() {
        var state = AddonPairingReducer.State()
        let original = delivery(id: "replace-me", token: "replacement-session", deliveryRevision: 1)
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([original], sessionToken: original.sessionToken, liveToken: original.sessionToken,
                        revision: original.revision),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: original.id, outcome: .ready(name: "Original"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: original.id, authoritySession: original.sessionToken, authorityGeneration: 0,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )

        let replacement = AddonPairingReducer.Delivery(
            id: original.id,
            url: "https://replacement.example/manifest.json",
            identity: "https://replacement.example/manifest.json",
            sessionToken: original.sessionToken,
            revision: original.revision + 1,
            status: .pending,
            deliveryRevision: 2
        )
        let replacementEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([replacement], sessionToken: replacement.sessionToken,
                        liveToken: replacement.sessionToken, revision: replacement.revision),
            normalize: normalize
        )
        expect(replacementEffects.contains(where: { if case let .resolveDurable(ticket, url) = $0 {
                   return ticket.rowID == replacement.id && ticket.revision == replacement.revision &&
                       ticket.deliveryRevision == replacement.deliveryRevision &&
                       ticket.identity == replacement.identity && url == replacement.url
               }; return false }) &&
               state.rows[0].url == replacement.url && state.rows[0].state == .resolving &&
               state.rows[0].deliveryRevision == replacement.deliveryRevision,
               "replacement: higher delivery revision swaps URL atomically and re-resolves")

        let stale = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: original.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        expect(stale.isEmpty && state.rows[0].state == .resolving && state.rows[0].acked == nil &&
               state.pendingAcks[original.id] == nil,
               "replacement: old install completion cannot acknowledge the replacement")
    }

    private static func closedSessionDrainsBeforeRelease() {
        var state = AddonPairingReducer.State()
        let d = delivery(token: "closed-session")
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: d.sessionToken, authorityGeneration: 0,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let beforeConfirm = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: d.sessionToken),
            normalize: normalize
        )
        expect(beforeConfirm.isEmpty && !state.isSessionReleased(d.sessionToken),
               "drain: closed session stays alive while install is in flight")

        let ackEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        let mutationID = ackEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        let afterConfirm = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .installed,
                         authoritySession: d.sessionToken, authorityGeneration: 0,
                         attempt: 1, deliveryRevision: 1, revision: d.revision, retryable: false,
                         mutationID: mutationID, success: true),
            normalize: normalize
        )
        let releaseEffect = afterConfirm.compactMap { effect -> (String, String, Int, String)? in
            if case let .releaseSession(token, authoritySession, authorityGeneration, mutationID) = effect {
                return (token, authoritySession, authorityGeneration, mutationID)
            }
            return nil
        }.first
        expect(releaseEffect?.0 == d.sessionToken && !state.isSessionReleased(d.sessionToken),
               "drain: release is queued only after local work drains, before network confirmation")
        let release = releaseEffect!
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: release.0, success: false),
            normalize: normalize
        )
        expect(!state.isSessionReleased(d.sessionToken),
               "release: a retryable network failure cannot release the session locally")
        let retry = AddonPairingReducer.reduce(
            &state,
            .retryPendingWork(sessionToken: d.sessionToken),
            normalize: normalize
        )
        expect(retry.contains(where: { if case .releaseSession = $0 { return true }; return false }),
               "release: failed close release is re-enqueued")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: d.sessionToken, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(d.sessionToken),
               "release: only a confirmed relay release seals the local session")
    }

    private static func restartUsesDurableDeliveryIdentity() {
        let d = delivery(id: "stable-after-restart", status: .installed)
        var restarted = AddonPairingReducer.State()
        let effects = AddonPairingReducer.reduce(
            &restarted,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        expect(effects.isEmpty && restarted.rows.count == 1 && restarted.rows[0].state == .installed,
               "restart: relay-confirmed durable delivery is not auto-installed again")

        let replay = AddonPairingReducer.reduce(
            &restarted,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision + 1),
            normalize: normalize
        )
        expect(replay.isEmpty && restarted.rows.count == 1,
               "restart: a later poll keeps the same durable delivery row")
    }

    private static func strictRelayValuesFailClosed() {
        let token = "abcdefghijklmnopqrstuv12"
        expect(AddonPairingClient.isStrictToken(token), "relay token: canonical-length opaque token is accepted")
        expect(!AddonPairingClient.isStrictToken("abc-XYZ_123"), "relay token: short token is rejected")
        expect(!AddonPairingClient.isStrictToken("../pair/other"), "relay token: path traversal token is rejected")
        expect(!AddonPairingClient.isStrictToken("token with spaces"), "relay token: whitespace token is rejected")
        expect(AddonPairingClient.isTrustedPageURL("https://add.vortx.tv/p#\(token)"),
               "relay page: trusted HTTPS origin is accepted")
        expect(!AddonPairingClient.isTrustedPageURL("https://add.vortx.tv/p/\(token)"),
               "relay page: token-bearing path is rejected")
        expect(!AddonPairingClient.isTrustedPageURL("http://add.vortx.tv/p#\(token)"),
               "relay page: HTTP origin is rejected")
        expect(!AddonPairingClient.isTrustedPageURL("https://evil.example/p#\(token)"),
               "relay page: foreign origin is rejected")
        expect(!AddonPairingClient.isTrustedPageURL("https://user:pass@add.vortx.tv/p#\(token)"),
               "relay page: credential-bearing / fragment URL is rejected")
        expect(safeRevision(.nan) == 0 && safeRevision(Double.greatestFiniteMagnitude) == Int.max,
               "relay revision: NaN and overflow clamp without trapping")
    }

    private static func strictManifestURLContractIsEnforced() {
        let valid = "https://addon.example/manifest.json"
        let oversized = "https://addon.example/" + String(repeating: "a", count: 2048) + ".json"
        expect(AddonPairingProtocol.isStrictManifestURL(valid),
               "manifest URL: canonical HTTPS URL is accepted")
        expect(!AddonPairingProtocol.isStrictManifestURL("http://addon.example/manifest.json") &&
               !AddonPairingProtocol.isStrictManifestURL("https://user:pass@addon.example/manifest.json") &&
               !AddonPairingProtocol.isStrictManifestURL("https://addon.example/manifest.json#secret") &&
               !AddonPairingProtocol.isStrictManifestURL(oversized),
               "manifest URL: HTTP, userinfo, fragments, and oversized values fail closed")
    }

    private static func mutationResponsesAreBoundToState() {
        let manifest: [String: Any] = [
            "id": "delivery-1",
            "url": "https://addon.example/manifest.json",
            "addedAt": 1_700_000_000_000,
            "status": "pending",
            "retryable": false,
            "attempt": 0,
            "deliveryRev": 0,
            "claimed": false,
        ]
        let valid: [String: Any] = [
            "ok": true,
            "duplicate": false,
            "proto": AddonPairingProtocol.version,
            "manifests": [manifest],
            "rev": 7,
            "generation": 3,
            "expiresAt": 1_700_000_600_000,
            "closed": false,
            "terminal": false,
            "released": false,
            "report": [String: Any](),
        ]
        expect(AddonPairingClient.isValidMutationResponse(valid, expectedGeneration: 3),
               "mutation response: common state and generation are required")
        var wrongProto = valid
        wrongProto["proto"] = 1
        var wrongGeneration = valid
        wrongGeneration["generation"] = 2
        var wrongOK = valid
        wrongOK["ok"] = false
        expect(!AddonPairingClient.isValidMutationResponse(wrongProto, expectedGeneration: 3) &&
               !AddonPairingClient.isValidMutationResponse(wrongGeneration, expectedGeneration: 3) &&
               !AddonPairingClient.isValidMutationResponse(wrongOK, expectedGeneration: 3),
               "mutation response: weak 2xx bodies cannot advance local state")
    }

    private static func releaseTombstoneResponseIsStrict() {
        let tombstone: [String: Any] = [
            "ok": true,
            "duplicate": true,
            "proto": AddonPairingProtocol.version,
            "released": true,
        ]
        expect(AddonPairingClient.isValidReleaseResponse(tombstone, expectedGeneration: 3),
               "release replay: the bounded duplicate tombstone is accepted without session data")

        var exposed = tombstone
        exposed[AddonPairingProtocol.Field.manifests] = [["url": "https://secret.example/manifest.json"]]
        var notReleased = tombstone
        notReleased[AddonPairingProtocol.Field.released] = false
        var notDuplicate = tombstone
        notDuplicate[AddonPairingProtocol.Field.duplicate] = false
        expect(!AddonPairingClient.isValidReleaseResponse(exposed, expectedGeneration: 3) &&
               !AddonPairingClient.isValidReleaseResponse(notReleased, expectedGeneration: 3) &&
               !AddonPairingClient.isValidReleaseResponse(notDuplicate, expectedGeneration: 3),
               "release replay: exposed, unreleased, or non-duplicate bodies fail closed")
    }

    private static func pendingInstalledAcknowledgement(
        token: String = "claim-phase-session",
        authoritySession: String = "current-authority",
        authorityGeneration: Int = 2
    ) -> (AddonPairingReducer.State, AddonPairingReducer.Delivery, String) {
        var state = AddonPairingReducer.State()
        let d = delivery(id: "claim-phase-delivery", token: token, revision: 7)
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: authoritySession, generation: authorityGeneration),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: authoritySession,
                           authorityGeneration: authorityGeneration,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let ackEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        _ = ackEffects
        let requeued = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: authoritySession, generation: authorityGeneration),
            normalize: normalize
        )
        let mutationID = requeued.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        return (state, d, mutationID)
    }

    private static func lateClaimCompletionAfterStopIsFenced() {
        func assertLateCompletion(_ success: Bool, _ label: String) {
            var state: AddonPairingReducer.State
            let delivery: AddonPairingReducer.Delivery
            let mutationID: String
            (state, delivery, mutationID) = pendingInstalledAcknowledgement(
                token: "stop-fence-\(success ? "success" : "failure")"
            )
            let before = state
            let accepted = AddonPairingReducer.canDispatchAckClaimCompletion(
                state,
                deliveryID: delivery.id,
                authoritySession: "current-authority",
                authorityGeneration: 2,
                mutationID: mutationID,
                expectedGeneration: 2,
                currentGeneration: 3,
                taskIsCancelled: false
            )
            let effects: [AddonPairingReducer.Effect] = accepted
                ? AddonPairingReducer.reduce(
                    &state,
                    .ackClaimFinished(deliveryID: delivery.id, token: delivery.sessionToken,
                                      authoritySession: "current-authority", authorityGeneration: 2,
                                      attempt: 2, deliveryRevision: 2, mutationID: mutationID, success: success),
                    normalize: normalize
                )
                : []
            expect(!accepted && effects.isEmpty && state == before,
                   "stop fence: late claim \(label) dispatches no event, effect, or state mutation")
        }

        assertLateCompletion(true, "success")
        assertLateCompletion(false, "failure")

        var canceledState: AddonPairingReducer.State
        let canceledDelivery: AddonPairingReducer.Delivery
        let canceledMutationID: String
        (canceledState, canceledDelivery, canceledMutationID) = pendingInstalledAcknowledgement(
            token: "cancel-fence"
        )
        let canceledBefore = canceledState
        let canceledAccepted = AddonPairingReducer.canDispatchAckClaimCompletion(
            canceledState,
            deliveryID: canceledDelivery.id,
            authoritySession: "current-authority",
            authorityGeneration: 2,
            mutationID: canceledMutationID,
            expectedGeneration: 2,
            currentGeneration: 2,
            taskIsCancelled: true
        )
        expect(!canceledAccepted && canceledState == canceledBefore,
               "stop fence: cancellation suppresses a claim completion even without generation drift")
    }

    private static func claimAndAckFailuresUseDistinctPhases() {
        var state: AddonPairingReducer.State
        let original: AddonPairingReducer.Delivery
        let originalMutationID: String
        (state, original, originalMutationID) = pendingInstalledAcknowledgement()

        let claimFailure = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: original.id, token: original.sessionToken,
                              authoritySession: "current-authority", authorityGeneration: 2,
                              attempt: 1, deliveryRevision: 1, mutationID: originalMutationID, success: false),
            normalize: normalize
        )
        expect(claimFailure.contains(where: { if case let .poll(token, authoritySession, authorityGeneration) = $0 {
                   return token == original.sessionToken && authoritySession == "current-authority" && authorityGeneration == 2
               }; return false }) &&
               state.pendingAcks[original.id]?.requiresClaim == true &&
               state.pendingAcks[original.id]?.awaitingPoll == true &&
               state.pendingAcks[original.id]?.dispatched == false,
               "claim phase: a lost claim response waits for poll without clearing requiresClaim")

        let staleAckFailure = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: original.id, token: original.sessionToken, status: .installed,
                         authoritySession: "current-authority", authorityGeneration: 2,
                         attempt: 1, deliveryRevision: 1, revision: 7, retryable: false,
                         mutationID: originalMutationID, success: false),
            normalize: normalize
        )
        expect(staleAckFailure.isEmpty && state.pendingAcks[original.id]?.requiresClaim == true &&
               state.pendingAcks[original.id]?.awaitingPoll == true &&
               state.pendingAcks[original.id]?.mutationID == originalMutationID,
               "claim phase: a misclassified direct failure cannot downgrade the claim phase or revision")
        expect(AddonPairingReducer.reduce(
            &state,
            .retryPendingAck(deliveryID: original.id),
            normalize: normalize
        ).isEmpty,
               "claim phase: awaiting poll suppresses a direct stale ACK retry")

        let committedClaimPoll = AddonPairingReducer.Delivery(
            id: original.id,
            url: original.url,
            identity: original.identity,
            sessionToken: original.sessionToken,
            revision: 8,
            status: .pending,
            deliveryRevision: 2,
            attempt: 2,
            claimed: true
        )
        let rebasedEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([committedClaimPoll], sessionToken: original.sessionToken,
                        liveToken: original.sessionToken, revision: 8),
            normalize: normalize
        )
        let rebased = rebasedEffects.compactMap { effect -> (Int, Int, Int, String, Bool)? in
            if case let .ack(_, _, _, _, _, attempt, deliveryRevision, revision, _, mutationID, requiresClaim) = effect {
                return (attempt, deliveryRevision, revision, mutationID, requiresClaim)
            }
            return nil
        }.first
        expect(rebased?.0 == 2 && rebased?.1 == 2 && rebased?.2 == 8 && rebased?.4 == true &&
               rebased?.3 != originalMutationID && state.rows[0].state == .installed &&
               state.pendingAcks[original.id]?.mutationID == rebased?.3,
               "claim phase: a claimed/new-revision poll rebases before any ACK and preserves the local install")

        guard let rebased else { return }
        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: original.id, token: original.sessionToken,
                              authoritySession: "current-authority", authorityGeneration: 2,
                              attempt: 2, deliveryRevision: 2, mutationID: rebased.3, success: true),
            normalize: normalize
        )
        expect(state.pendingAcks[original.id]?.requiresClaim == false &&
               state.pendingAcks[original.id]?.awaitingPoll == false &&
               state.pendingAcks[original.id]?.dispatched == true,
               "claim phase: only a proven claim clears requiresClaim before ACK")

        let sameClaimPoll = AddonPairingReducer.Delivery(
            id: original.id,
            url: original.url,
            identity: original.identity,
            sessionToken: original.sessionToken,
            revision: 8,
            status: .pending,
            deliveryRevision: 2,
            attempt: 2,
            claimed: true
        )
        let sameClaimEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([sameClaimPoll], sessionToken: original.sessionToken,
                        liveToken: original.sessionToken, revision: 8),
            normalize: normalize
        )
        expect(sameClaimEffects.isEmpty && state.pendingAcks[original.id]?.mutationID == rebased.3 &&
               state.pendingAcks[original.id]?.requiresClaim == false,
               "ACK phase: a claimed poll after a proven claim does not mint a replacement mutation")

        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: original.id, token: original.sessionToken, status: .installed,
                         authoritySession: "current-authority", authorityGeneration: 2,
                         attempt: 2, deliveryRevision: 2, revision: 8, retryable: false,
                         mutationID: rebased.3, success: false),
            normalize: normalize
        )
        let retry = AddonPairingReducer.reduce(
            &state,
            .retryPendingAck(deliveryID: original.id),
            normalize: normalize
        )
        let retryAck = retry.compactMap { effect -> (String, Bool)? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect {
                return (mutationID, requiresClaim)
            }
            return nil
        }.first
        expect(state.pendingAcks[original.id]?.requiresClaim == false &&
               state.pendingAcks[original.id]?.awaitingPoll == false &&
               retryAck?.0 == rebased.3 && retryAck?.1 == false,
               "ACK phase: transport failure reuses the exact ACK mutation without reclaiming")
    }

    private static func foreignClaimPollRebasesBeforeRecovery() {
        var state: AddonPairingReducer.State
        let original: AddonPairingReducer.Delivery
        let originalMutationID: String
        (state, original, originalMutationID) = pendingInstalledAcknowledgement(
            token: "foreign-claim-session", authoritySession: "local-authority", authorityGeneration: 3
        )
        let foreignClaim = AddonPairingReducer.Delivery(
            id: original.id,
            url: original.url,
            identity: original.identity,
            sessionToken: original.sessionToken,
            revision: 8,
            status: .pending,
            deliveryRevision: 3,
            attempt: 2,
            claimed: true
        )
        let foreignEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([foreignClaim], sessionToken: original.sessionToken,
                        liveToken: original.sessionToken, revision: 8),
            normalize: normalize
        )
        let foreignMutationID = foreignEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect, requiresClaim {
                return mutationID
            }
            return nil
        }.first
        expect(foreignMutationID != nil && foreignMutationID != originalMutationID &&
               state.rows[0].state == .installed && state.rows[0].acked == nil &&
               !foreignEffects.contains(where: { if case .install = $0 { return true }; return false }),
               "foreign claim: claimed poll cannot attribute or reinstall the local result")
        guard let foreignMutationID else { return }

        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: original.id, token: original.sessionToken,
                              authoritySession: "local-authority", authorityGeneration: 3,
                              attempt: 2, deliveryRevision: 3, mutationID: foreignMutationID, success: false),
            normalize: normalize
        )
        let available = AddonPairingReducer.Delivery(
            id: original.id,
            url: original.url,
            identity: original.identity,
            sessionToken: original.sessionToken,
            revision: 9,
            status: .pending,
            deliveryRevision: 4,
            attempt: 2,
            claimed: false
        )
        let recoveryEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([available], sessionToken: original.sessionToken,
                        liveToken: original.sessionToken, revision: 9),
            normalize: normalize
        )
        let recovery = recoveryEffects.compactMap { effect -> (Int, Int, Int, String, Bool)? in
            if case let .ack(_, _, _, _, _, attempt, deliveryRevision, revision, _, mutationID, requiresClaim) = effect {
                return (attempt, deliveryRevision, revision, mutationID, requiresClaim)
            }
            return nil
        }.first
        expect(recovery?.0 == 2 && recovery?.1 == 4 && recovery?.2 == 9 && recovery?.4 == true &&
               recovery?.3 != foreignMutationID && state.pendingAcks[original.id]?.awaitingPoll == false,
               "foreign claim: an unclaimed poll adopts the exact server revision and reclaims under local authority")
        guard let recovery else { return }

        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: original.id, token: original.sessionToken,
                              authoritySession: "local-authority", authorityGeneration: 3,
                              attempt: 3, deliveryRevision: 5, mutationID: recovery.3, success: true),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: original.id, token: original.sessionToken, status: .installed,
                         authoritySession: "local-authority", authorityGeneration: 3,
                         attempt: 3, deliveryRevision: 5, revision: 9, retryable: false,
                         mutationID: recovery.3, success: true),
            normalize: normalize
        )
        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: original.sessionToken),
            normalize: normalize
        )
        expect(state.rows[0].acked == .installed && state.pendingAcks[original.id] == nil &&
               release.contains(where: { if case .releaseSession = $0 { return true }; return false }),
               "foreign claim: recovered ACK drains before release")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: original.sessionToken, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(original.sessionToken),
               "foreign claim: confirmed release succeeds after recovery")
    }

    private static func manualRetryUsesServerClaimTupleAndDrains() {
        var state = AddonPairingReducer.State()
        let d = delivery(id: "manual-retry-delivery", token: "manual-retry-session")
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: "manual-retry-authority", generation: 1),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: "manual-retry-authority", authorityGeneration: 1,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let failedEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .failed("first attempt failed")),
            normalize: normalize
        )
        let failedMutationID = failedEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .failed,
                         authoritySession: "manual-retry-authority", authorityGeneration: 1,
                         attempt: 1, deliveryRevision: 1, revision: d.revision, retryable: false,
                         mutationID: failedMutationID, success: false),
            normalize: normalize
        )
        let failed: Bool
        if case .failed = state.rows[0].state { failed = true } else { failed = false }
        expect(failed && state.rows[0].attempt == 1 && state.rows[0].deliveryRevision == 1 &&
               state.pendingAcks[d.id] != nil,
               "manual retry: failed ACK transport retains the last server claim tuple")

        let replayOldAck = AddonPairingReducer.reduce(
            &state,
            .manualInstall(rowId: d.id),
            normalize: normalize
        )
        let replayTuple = replayOldAck.compactMap { effect -> (Int, Int, String)? in
            if case let .ack(_, _, _, _, _, attempt, deliveryRevision, _, _, mutationID, _) = effect {
                return (attempt, deliveryRevision, mutationID)
            }
            return nil
        }.first
        expect(replayTuple?.0 == 1 && replayTuple?.1 == 1 && replayTuple?.2 == failedMutationID &&
               state.rows[0].attempt == 1,
               "manual retry: unsettled ACK is replayed with the exact old attempt and mutation")
        guard let replayTuple else { return }

        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .failed,
                         authoritySession: "manual-retry-authority", authorityGeneration: 1,
                         attempt: replayTuple.0, deliveryRevision: replayTuple.1, revision: d.revision,
                         retryable: false, mutationID: replayTuple.2, success: true),
            normalize: normalize
        )

        let serverRevision = d.revision + 1
        let serverFailed = AddonPairingReducer.Delivery(
            id: d.id, url: d.url, identity: d.identity, sessionToken: d.sessionToken,
            revision: serverRevision, status: .failed, deliveryRevision: 2, attempt: 1, claimed: false
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([serverFailed], sessionToken: d.sessionToken, liveToken: d.sessionToken,
                        revision: serverRevision),
            normalize: normalize
        )
        let retryClaim = AddonPairingReducer.reduce(
            &state,
            .manualInstall(rowId: d.id),
            normalize: normalize
        )
        expect(retryClaim == [.claim(deliveryID: d.id, token: d.sessionToken, deliveryRevision: 2,
                                     authoritySession: "manual-retry-authority", authorityGeneration: 1)] &&
               state.rows[0].attempt == 1 && state.rows[0].deliveryRevision == 2,
               "manual retry: server poll is reconciled before minting a new claim tuple")

        let reclaimed = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: "manual-retry-authority", authorityGeneration: 1,
                           attempt: 2, deliveryRevision: 3, success: true),
            normalize: normalize
        )
        expect(reclaimed == [.installAttempt(rowId: d.id, url: d.url, attempt: 2)] &&
               state.rows[0].attempt == 2 && state.rows[0].deliveryRevision == 3,
               "manual retry: the fresh server claim tuple starts the next install")

        let ackEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 2, outcome: .installed),
            normalize: normalize
        )
        let ackTuple = ackEffects.compactMap { effect -> (Int, Int, String)? in
            if case let .ack(_, _, _, _, _, attempt, deliveryRevision, _, _, mutationID, _) = effect {
                return (attempt, deliveryRevision, mutationID)
            }
            return nil
        }.first
        expect(ackTuple?.0 == 2 && ackTuple?.1 == 3,
               "manual retry: installed ACK uses the fresh server-returned attempt and delivery revision")
        guard let ackTuple else { return }

        let drained = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .installed,
                         authoritySession: "manual-retry-authority", authorityGeneration: 1,
                         attempt: ackTuple.0, deliveryRevision: ackTuple.1, revision: serverRevision,
                         retryable: false, mutationID: ackTuple.2, success: true),
            normalize: normalize
        )
        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: d.sessionToken),
            normalize: normalize
        )
        expect(drained.isEmpty && state.pendingAcks[d.id] == nil &&
               release.contains(where: { if case .releaseSession = $0 { return true }; return false }),
               "manual retry: confirmed ACK drains the session and queues release")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: d.sessionToken, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(d.sessionToken),
               "manual retry: confirmed release seals the recovered session")
    }

    private static func manualRetryWaitsForLiveAckMutation() {
        var state = AddonPairingReducer.State()
        let d = delivery(id: "live-ack-retry-delivery", token: "live-ack-retry-session")
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: "live-ack-authority", generation: 1),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: "live-ack-authority", authorityGeneration: 1,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let oldAckEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .failed("first attempt failed")),
            normalize: normalize
        )
        let oldMutationID = oldAckEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        let pendingBeforeRetry = state.pendingAcks[d.id]

        let blocked = AddonPairingReducer.reduce(
            &state,
            .manualInstall(rowId: d.id),
            normalize: normalize
        )
        expect(blocked.isEmpty && state.pendingAcks[d.id] == pendingBeforeRetry &&
               state.pendingAcks[d.id]?.mutationID == oldMutationID &&
               state.pendingAcks[d.id]?.dispatched == true && state.rows[0].attempt == 1,
               "manual retry: a live old ACK stays authoritative and cannot start a same-attempt reinstall")

        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .failed,
                         authoritySession: "live-ack-authority", authorityGeneration: 1,
                         attempt: 1, deliveryRevision: 1, revision: d.revision, retryable: false,
                         mutationID: oldMutationID, success: true),
            normalize: normalize
        )
        let retry = AddonPairingReducer.reduce(
            &state,
            .manualInstall(rowId: d.id),
            normalize: normalize
        )
        expect(retry == [.claim(deliveryID: d.id, token: d.sessionToken, deliveryRevision: 1,
                                authoritySession: "live-ack-authority", authorityGeneration: 1)] &&
               state.pendingAcks[d.id] == nil,
               "manual retry: only a settled ACK permits reclaim and reinstall")
    }

    private static func installedCanonicalState(
        token: String,
        authoritySession: String,
        authorityGeneration: Int
    ) -> (AddonPairingReducer.State, AddonPairingReducer.Delivery) {
        var state = AddonPairingReducer.State()
        let canonical = delivery(id: "terminal-canonical-row", token: token, revision: 7)
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([canonical], sessionToken: token, liveToken: token, revision: canonical.revision),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: authoritySession, generation: authorityGeneration),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: canonical.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: canonical.id, authoritySession: authoritySession,
                           authorityGeneration: authorityGeneration,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let ackEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: canonical.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        let mutationID = ackEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: canonical.id, token: token, status: .installed,
                         authoritySession: authoritySession, authorityGeneration: authorityGeneration,
                         attempt: 1, deliveryRevision: 1, revision: canonical.revision,
                         retryable: false, mutationID: mutationID, success: true),
            normalize: normalize
        )
        return (state, canonical)
    }

    private static func terminalDuplicateClaimLossRebasesWithoutRow() {
        let token = "terminal-duplicate-loss-session"
        let authoritySession = "terminal-duplicate-loss-authority"
        var state: AddonPairingReducer.State
        let canonical: AddonPairingReducer.Delivery
        (state, canonical) = installedCanonicalState(
            token: token, authoritySession: authoritySession, authorityGeneration: 1
        )
        let duplicate = delivery(id: "terminal-duplicate-loss-delivery", token: token, revision: 8)
        let initial = AddonPairingReducer.reduce(
            &state,
            .deliveries([duplicate], sessionToken: token, liveToken: token, revision: duplicate.revision),
            normalize: normalize
        )
        let initialMutationID = initial.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect, requiresClaim {
                return mutationID
            }
            return nil
        }.first ?? ""
        expect(initialMutationID.isEmpty == false && state.rows.count == 1 &&
               state.rows[0].id == canonical.id && state.rows[0].acked == .installed &&
               state.pendingAcks[duplicate.id]?.requiresClaim == true &&
               state.pendingAcks[duplicate.id]?.awaitingPoll == false,
               "terminal duplicate: duplicate ACK is keyed by delivery ID without creating a second install row")

        var proven = state
        _ = AddonPairingReducer.reduce(
            &proven,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: authoritySession, authorityGeneration: 1,
                              attempt: 1, deliveryRevision: 1,
                              mutationID: initialMutationID, success: true),
            normalize: normalize
        )
        let sameTuple = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity,
            sessionToken: token, revision: 9, status: .pending,
            deliveryRevision: 1, attempt: 1, claimed: true
        )
        let inFlightPoll = AddonPairingReducer.reduce(
            &proven,
            .deliveries([sameTuple], sessionToken: token, liveToken: token, revision: 9),
            normalize: normalize
        )
        expect(inFlightPoll.isEmpty && proven.pendingAcks[duplicate.id]?.mutationID == initialMutationID &&
               proven.pendingAcks[duplicate.id]?.requiresClaim == false,
               "terminal duplicate: a same-tuple poll cannot replace a proven ACK already in flight")

        let lostClaim = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: authoritySession, authorityGeneration: 1,
                              attempt: 1, deliveryRevision: 1,
                              mutationID: initialMutationID, success: false),
            normalize: normalize
        )
        expect(lostClaim == [.poll(token: token, authoritySession: authoritySession, authorityGeneration: 1)] &&
               state.pendingAcks[duplicate.id]?.awaitingPoll == true,
               "terminal duplicate: lost claim response enters bounded poll recovery")

        let polled = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity,
            sessionToken: token, revision: 9, status: .pending,
            deliveryRevision: 1, attempt: 1, claimed: true
        )
        let recovery = AddonPairingReducer.reduce(
            &state,
            .deliveries([polled], sessionToken: token, liveToken: token, revision: polled.revision),
            normalize: normalize
        )
        let rebased = recovery.compactMap { effect -> (Int, Int, Int, String, Bool)? in
            if case let .ack(_, _, _, _, _, attempt, deliveryRevision, revision, _, mutationID, requiresClaim) = effect {
                return (attempt, deliveryRevision, revision, mutationID, requiresClaim)
            }
            return nil
        }.first
        expect(rebased?.0 == 1 && rebased?.1 == 1 && rebased?.2 == 9 && rebased?.4 == true &&
               rebased?.3 != initialMutationID && state.rows.count == 1 &&
               state.rows[0].id == canonical.id && state.rows[0].acked == .installed &&
               state.pendingAcks[duplicate.id]?.awaitingPoll == false,
               "terminal duplicate: delivery-ID poll rebase works without a row and preserves exactly-once install")
        guard let rebased else { return }

        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: authoritySession, authorityGeneration: 1,
                              attempt: 2, deliveryRevision: 2,
                              mutationID: rebased.3, success: true),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: duplicate.id, token: token, status: .installed,
                         authoritySession: authoritySession, authorityGeneration: 1,
                         attempt: 2, deliveryRevision: 2, revision: 9,
                         retryable: false, mutationID: rebased.3, success: true),
            normalize: normalize
        )
        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: token),
            normalize: normalize
        )
        expect(state.pendingAcks[duplicate.id] == nil && state.rows.count == 1 &&
               state.rows[0].acked == .installed &&
               release.contains(where: { if case .releaseSession = $0 { return true }; return false }),
               "terminal duplicate: recovered ACK drains the canonical row before release")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: token, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(token),
               "terminal duplicate: confirmed release seals the duplicate-recovered session")
    }

    private static func terminalDuplicateForeignClaimReopenDrains() {
        let token = "terminal-duplicate-reopen-session"
        let oldAuthority = "terminal-duplicate-old-authority"
        var state: AddonPairingReducer.State
        let canonical: AddonPairingReducer.Delivery
        (state, canonical) = installedCanonicalState(
            token: token, authoritySession: oldAuthority, authorityGeneration: 1
        )
        let duplicate = delivery(id: "terminal-duplicate-reopen-delivery", token: token, revision: 8)
        let initial = AddonPairingReducer.reduce(
            &state,
            .deliveries([duplicate], sessionToken: token, liveToken: token, revision: duplicate.revision),
            normalize: normalize
        )
        let initialMutationID = initial.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect, requiresClaim {
                return mutationID
            }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: oldAuthority, authorityGeneration: 1,
                              attempt: 1, deliveryRevision: 1,
                              mutationID: initialMutationID, success: false),
            normalize: normalize
        )
        let foreign = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity,
            sessionToken: token, revision: 9, status: .pending,
            deliveryRevision: 1, attempt: 1, claimed: true
        )
        let foreignEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([foreign], sessionToken: token, liveToken: token, revision: 9),
            normalize: normalize
        )
        let foreignMutationID = foreignEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect, requiresClaim {
                return mutationID
            }
            return nil
        }.first ?? ""
        expect(foreignMutationID.isEmpty == false && foreignMutationID != initialMutationID &&
               state.rows.count == 1 && state.rows[0].id == canonical.id &&
               state.pendingAcks[duplicate.id]?.requiresClaim == true,
               "terminal duplicate: an undisclosed foreign claim stays fenced without attributing install")

        let staleForeign = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: duplicate.id, token: token, status: .installed,
                         authoritySession: oldAuthority, authorityGeneration: 1,
                         attempt: 1, deliveryRevision: 1, revision: 9,
                         retryable: false, mutationID: foreignMutationID, success: true),
            normalize: normalize
        )
        expect(staleForeign.isEmpty && state.pendingAcks[duplicate.id]?.requiresClaim == true,
               "terminal duplicate: stale foreign completion cannot publish the installed ACK")

        _ = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: "terminal-duplicate-new-authority", generation: 2),
            normalize: normalize
        )
        let reopened = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity,
            sessionToken: token, revision: 10, status: .pending,
            deliveryRevision: 2, attempt: 1, claimed: false
        )
        let reopenedEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([reopened], sessionToken: token, liveToken: token, revision: 10),
            normalize: normalize
        )
        let rebased = reopenedEffects.compactMap { effect -> (Int, Int, Int, String, Bool)? in
            if case let .ack(_, _, _, _, _, attempt, deliveryRevision, revision, _, mutationID, requiresClaim) = effect {
                return (attempt, deliveryRevision, revision, mutationID, requiresClaim)
            }
            return nil
        }.first
        expect(rebased?.0 == 1 && rebased?.1 == 2 && rebased?.2 == 10 && rebased?.4 == true &&
               rebased?.3 != foreignMutationID && state.pendingAcks[duplicate.id]?.authorityGeneration == 2,
               "terminal duplicate: reopen rebase adopts the exact delivery tuple without a row")
        guard let rebased else { return }

        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: "terminal-duplicate-new-authority", authorityGeneration: 2,
                              attempt: 2, deliveryRevision: 3,
                              mutationID: rebased.3, success: true),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: duplicate.id, token: token, status: .installed,
                         authoritySession: "terminal-duplicate-new-authority", authorityGeneration: 2,
                         attempt: 2, deliveryRevision: 3, revision: 10,
                         retryable: false, mutationID: rebased.3, success: true),
            normalize: normalize
        )
        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: token),
            normalize: normalize
        )
        expect(state.pendingAcks[duplicate.id] == nil && state.rows.count == 1 &&
               state.rows[0].id == canonical.id && state.rows[0].acked == .installed &&
               release.contains(where: { if case .releaseSession = $0 { return true }; return false }),
               "terminal duplicate: foreign-claim recovery drains before release")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: token, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(token),
               "terminal duplicate: reopened duplicate session releases only after confirmed drain")
    }

    private static func terminalDuplicateReplacementRebasesByDeliveryID() {
        let token = "terminal-duplicate-replacement-session"
        let authority = "terminal-duplicate-replacement-authority"
        var state: AddonPairingReducer.State
        let canonical: AddonPairingReducer.Delivery
        (state, canonical) = installedCanonicalState(token: token, authoritySession: authority, authorityGeneration: 1)

        let duplicate = delivery(id: "terminal-duplicate-replacement-delivery", token: token, revision: 8)
        let initial = AddonPairingReducer.reduce(
            &state,
            .deliveries([duplicate], sessionToken: token, liveToken: token, revision: duplicate.revision),
            normalize: normalize
        )
        let initialMutationID = initial.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect, requiresClaim {
                return mutationID
            }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: authority, authorityGeneration: 1,
                              attempt: 1, deliveryRevision: 1,
                              mutationID: initialMutationID, success: true),
            normalize: normalize
        )

        let oldAckFailure = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: duplicate.id, token: token, status: .installed,
                         authoritySession: authority, authorityGeneration: 1,
                         attempt: 1, deliveryRevision: 1, revision: duplicate.revision,
                         retryable: false, mutationID: initialMutationID, success: false),
            normalize: normalize
        )
        expect(oldAckFailure.isEmpty && state.pendingAcks[duplicate.id]?.requiresClaim == false &&
               state.pendingAcks[duplicate.id]?.dispatched == false,
               "terminal duplicate replacement: ACK response loss retains the old mutation until authoritative poll")

        let replacementURL = "https://replacement.example/manifest.json"
        let replacement = AddonPairingReducer.Delivery(
            id: duplicate.id,
            url: replacementURL,
            identity: replacementURL,
            sessionToken: token,
            revision: 10,
            status: .pending,
            deliveryRevision: 2,
            attempt: 1,
            retryable: false,
            claimed: false
        )
        let effects = AddonPairingReducer.reduce(
            &state,
            .deliveries([replacement], sessionToken: token, liveToken: token, revision: replacement.revision),
            normalize: normalize
        )
        expect(effects.contains(where: { if case let .resolveDurable(ticket, url) = $0 {
                   return ticket.rowID == duplicate.id && ticket.deliveryRevision == replacement.deliveryRevision &&
                       ticket.identity == replacementURL && url == replacementURL
               }; return false }) && state.pendingAcks[duplicate.id] == nil && state.rows.count == 2 &&
               state.rows[0].id == canonical.id && state.rows[0].url == canonical.url &&
               state.rows.contains(where: { $0.id == duplicate.id && $0.url == replacementURL &&
                   $0.revision == 10 && $0.deliveryRevision == 2 && $0.attempt == 1 &&
                   $0.state == .resolving && $0.acked == nil }),
               "terminal duplicate replacement: changed identity discards the old ACK and materializes the exact newer row")

        let lateOldAck = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: duplicate.id, token: token, status: .installed,
                         authoritySession: authority, authorityGeneration: 1,
                         attempt: 1, deliveryRevision: 1, revision: duplicate.revision,
                         retryable: false, mutationID: initialMutationID, success: true),
            normalize: normalize
        )
        expect(lateOldAck.isEmpty && state.rows.first(where: { $0.id == duplicate.id })?.state == .resolving,
               "terminal duplicate replacement: late old ACK cannot mutate the replacement row")

        let claimEffects = reduceDurableResolved(&state, rowID: duplicate.id, outcome: .ready(name: "Replacement"))
        expect(claimEffects.contains(where: { if case let .claim(deliveryID, _, deliveryRevision, _, _) = $0 {
                   return deliveryID == duplicate.id && deliveryRevision == 2
               }; return false }),
               "terminal duplicate replacement: real replacement row claims its exact relay revision")
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: duplicate.id, authoritySession: authority, authorityGeneration: 1,
                           attempt: 2, deliveryRevision: 3, success: true),
            normalize: normalize
        )
        let freshAckEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: duplicate.id, attempt: 2, outcome: .installed),
            normalize: normalize
        )
        let freshMutationID = freshAckEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: duplicate.id, token: token, status: .installed,
                         authoritySession: authority, authorityGeneration: 1,
                         attempt: 2, deliveryRevision: 3, revision: 10,
                         retryable: false, mutationID: freshMutationID, success: true),
            normalize: normalize
        )
        let stale = AddonPairingReducer.Delivery(
            id: duplicate.id, url: replacementURL, identity: replacementURL, sessionToken: token,
            revision: 11, status: .pending, deliveryRevision: 2, attempt: 1,
            retryable: false, claimed: true
        )
        let staleEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([stale], sessionToken: token, liveToken: token, revision: stale.revision),
            normalize: normalize
        )
        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: token),
            normalize: normalize
        )
        expect(staleEffects.isEmpty && state.pendingAcks[duplicate.id] == nil && state.rows.count == 2 &&
               state.rows.first(where: { $0.id == duplicate.id })?.state == .installed &&
               state.rows.first(where: { $0.id == duplicate.id })?.deliveryRevision == 3 &&
               release.filter({ if case .releaseSession = $0 { return true }; return false }).count == 1,
               "terminal duplicate replacement: real install/ACK rejects stale poll and drains before one release")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: token, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(token),
               "terminal duplicate replacement: confirmed release seals the response-loss recovery")
    }

    private static func terminalDuplicateFailedForeignClaimDrains() {
        let token = "terminal-duplicate-failed-session"
        let authority = "terminal-duplicate-failed-authority"
        var state: AddonPairingReducer.State
        let canonical: AddonPairingReducer.Delivery
        (state, canonical) = installedCanonicalState(token: token, authoritySession: authority, authorityGeneration: 1)

        let duplicate = delivery(id: "terminal-duplicate-failed-delivery", token: token, revision: 8)
        let initial = AddonPairingReducer.reduce(
            &state,
            .deliveries([duplicate], sessionToken: token, liveToken: token, revision: duplicate.revision),
            normalize: normalize
        )
        let initialMutationID = initial.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect, requiresClaim {
                return mutationID
            }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: authority, authorityGeneration: 1,
                              attempt: 1, deliveryRevision: 1,
                              mutationID: initialMutationID, success: false),
            normalize: normalize
        )

        let foreign = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity, sessionToken: token,
            revision: 9, status: .pending, deliveryRevision: 1, attempt: 1,
            retryable: false, claimed: true
        )
        let foreignEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([foreign], sessionToken: token, liveToken: token, revision: foreign.revision),
            normalize: normalize
        )
        let foreignMutationID = foreignEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect, requiresClaim {
                return mutationID
            }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: authority, authorityGeneration: 1,
                              attempt: 1, deliveryRevision: 1,
                              mutationID: foreignMutationID, success: false),
            normalize: normalize
        )

        let failed = AddonPairingReducer.Delivery(
            id: duplicate.id, url: foreign.url, identity: foreign.identity, sessionToken: token,
            revision: 12, status: .failed, deliveryRevision: 2, attempt: 1,
            retryable: false, claimed: false
        )
        let terminalEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([failed], sessionToken: token, liveToken: token, revision: failed.revision),
            normalize: normalize
        )
        expect(terminalEffects.isEmpty && state.pendingAcks[duplicate.id] == nil &&
               state.acknowledgedDeliveryRevisions[duplicate.id] != nil && state.rows.count == 1 &&
               state.rows[0].id == canonical.id && state.rows[0].acked == .installed &&
               !state.isInFlight(sessionToken: token),
               "terminal duplicate failure: foreign terminal failed poll removes the no-row ACK without attributing failure to the canonical install")

        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: token),
            normalize: normalize
        )
        expect(release.filter({ if case .releaseSession = $0 { return true }; return false }).count == 1,
               "terminal duplicate failure: terminal no-row outcome drains exactly once before release")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: token, success: true),
            normalize: normalize
        )
        let secondClose = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: token),
            normalize: normalize
        )
        expect(state.isSessionReleased(token) && secondClose.isEmpty,
               "terminal duplicate failure: confirmed release cannot be emitted twice")
    }

    private static func terminalDuplicateStaleRevisionCannotOverwrite() {
        let token = "terminal-duplicate-stale-session"
        let authority = "terminal-duplicate-stale-authority"
        var state: AddonPairingReducer.State
        let canonical: AddonPairingReducer.Delivery
        (state, canonical) = installedCanonicalState(token: token, authoritySession: authority, authorityGeneration: 1)
        let duplicate = delivery(id: "terminal-duplicate-stale-delivery", token: token, revision: 8)
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([duplicate], sessionToken: token, liveToken: token, revision: duplicate.revision),
            normalize: normalize
        )

        let newer = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url,
            identity: duplicate.identity, sessionToken: token,
            revision: 10, status: .pending, deliveryRevision: 2, attempt: 1,
            retryable: false, claimed: false
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([newer], sessionToken: token, liveToken: token, revision: newer.revision),
            normalize: normalize
        )
        let newerPending = state.pendingAcks[duplicate.id]
        let stalePending = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity, sessionToken: token,
            revision: 11, status: .pending, deliveryRevision: 1, attempt: 1,
            retryable: false, claimed: true
        )
        let stalePendingEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([stalePending], sessionToken: token, liveToken: token, revision: stalePending.revision),
            normalize: normalize
        )
        expect(stalePendingEffects.isEmpty && state.pendingAcks[duplicate.id] == newerPending &&
               state.rows.count == 1 && state.rows[0].url == canonical.url,
               "terminal duplicate stale: older pending delivery revision cannot rewind the newer no-row tuple")

        let terminal = AddonPairingReducer.Delivery(
            id: duplicate.id, url: newer.url, identity: newer.identity, sessionToken: token,
            revision: 12, status: .failed, deliveryRevision: 3, attempt: 1,
            retryable: false, claimed: false
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([terminal], sessionToken: token, liveToken: token, revision: terminal.revision),
            normalize: normalize
        )
        let staleTerminal = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity, sessionToken: token,
            revision: 13, status: .installed, deliveryRevision: 2, attempt: 1,
            retryable: false, claimed: false
        )
        let staleTerminalEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([staleTerminal], sessionToken: token, liveToken: token, revision: staleTerminal.revision),
            normalize: normalize
        )
        expect(staleTerminalEffects.isEmpty && state.pendingAcks[duplicate.id] == nil &&
               state.acknowledgedDeliveryRevisions[duplicate.id] != nil && state.rows.count == 1 &&
               state.rows[0].id == canonical.id && state.rows[0].url == canonical.url &&
               state.rows[0].acked == .installed,
               "terminal duplicate stale: older terminal result cannot overwrite the newer failed authority or canonical install")
    }

    private static func terminalDuplicateHighWaterReentersNormalIdentity() {
        let token = "terminal-high-water-session"
        let authority = "terminal-high-water-authority"
        var state: AddonPairingReducer.State
        let canonical: AddonPairingReducer.Delivery
        (state, canonical) = installedCanonicalState(token: token, authoritySession: authority, authorityGeneration: 1)
        let duplicate = delivery(id: "terminal-high-water-delivery", token: token, revision: 8)
        let initial = AddonPairingReducer.reduce(
            &state,
            .deliveries([duplicate], sessionToken: token, liveToken: token, revision: duplicate.revision),
            normalize: normalize
        )
        let initialMutationID = initial.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, requiresClaim) = effect, requiresClaim {
                return mutationID
            }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: authority, authorityGeneration: 1,
                              attempt: 1, deliveryRevision: 1,
                              mutationID: initialMutationID, success: true),
            normalize: normalize
        )
        let terminalPoll = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity, sessionToken: token,
            revision: 9, status: .installed, deliveryRevision: 2, attempt: 1,
            retryable: false, claimed: false
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([terminalPoll], sessionToken: token, liveToken: token, revision: terminalPoll.revision),
            normalize: normalize
        )
        expect(state.pendingAcks[duplicate.id] == nil && state.acknowledgedDeliveryRevisions[duplicate.id] != nil,
               "terminal high-water: installed poll commits the rowless duplicate's terminal high-water")

        let sameIdentity = AddonPairingReducer.Delivery(
            id: duplicate.id, url: duplicate.url, identity: duplicate.identity, sessionToken: token,
            revision: 10, status: .pending, deliveryRevision: 3, attempt: 1,
            retryable: false, claimed: false
        )
        let sameIdentityEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([sameIdentity], sessionToken: token, liveToken: token, revision: sameIdentity.revision),
            normalize: normalize
        )
        let sameMutationID = sameIdentityEffects.compactMap { effect -> String? in
            if case let .ack(_, _, status, _, _, _, deliveryRevision, revision, retryable, mutationID, requiresClaim) = effect,
               status == .installed, deliveryRevision == 3, revision == 10, !retryable, requiresClaim {
                return mutationID
            }
            return nil
        }.first ?? ""
        expect(!sameMutationID.isEmpty && sameMutationID != initialMutationID && state.rows.count == 1 &&
               state.rows[0].id == canonical.id && state.pendingAcks[duplicate.id]?.deliveryRevision == 3,
               "terminal high-water: same-identity higher revision creates a fresh rowless duplicate ACK")
        guard !sameMutationID.isEmpty else { return }

        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: duplicate.id, token: token,
                              authoritySession: authority, authorityGeneration: 1,
                              attempt: 2, deliveryRevision: 4,
                              mutationID: sameMutationID, success: true),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: duplicate.id, token: token, status: .installed,
                         authoritySession: authority, authorityGeneration: 1,
                         attempt: 2, deliveryRevision: 4, revision: 10,
                         retryable: false, mutationID: sameMutationID, success: true),
            normalize: normalize
        )

        let changedURL = "https://terminal-replacement.example/manifest.json"
        let changedIdentity = AddonPairingReducer.Delivery(
            id: duplicate.id, url: changedURL, identity: changedURL, sessionToken: token,
            revision: 12, status: .pending, deliveryRevision: 5, attempt: 2,
            retryable: false, claimed: false
        )
        let changedEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([changedIdentity], sessionToken: token, liveToken: token, revision: changedIdentity.revision),
            normalize: normalize
        )
        expect(changedEffects.contains(where: { if case let .resolveDurable(ticket, url) = $0 {
                   return ticket.rowID == duplicate.id && ticket.deliveryRevision == changedIdentity.deliveryRevision &&
                       ticket.identity == changedURL && url == changedURL
               }; return false }) && state.rows.count == 2 &&
               state.rows.contains(where: { $0.id == duplicate.id && $0.url == changedURL && $0.state == .resolving && $0.acked == nil }),
               "terminal high-water: changed-identity replacement materializes a real row instead of reusing installed state")

        let claimEffects = reduceDurableResolved(&state, rowID: duplicate.id, outcome: .ready(name: "Replacement"))
        expect(claimEffects.contains(where: { if case let .claim(deliveryID, _, deliveryRevision, _, _) = $0 {
                   return deliveryID == duplicate.id && deliveryRevision == 5
               }; return false }),
               "terminal high-water: changed replacement claims its exact newer delivery revision")
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: duplicate.id, authoritySession: authority, authorityGeneration: 1,
                           attempt: 3, deliveryRevision: 6, success: true),
            normalize: normalize
        )
        let ackEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: duplicate.id, attempt: 3, outcome: .installed),
            normalize: normalize
        )
        let replacementMutationID = ackEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: duplicate.id, token: token, status: .installed,
                         authoritySession: authority, authorityGeneration: 1,
                         attempt: 3, deliveryRevision: 6, revision: 12,
                         retryable: false, mutationID: replacementMutationID, success: true),
            normalize: normalize
        )

        let stale = AddonPairingReducer.Delivery(
            id: duplicate.id, url: changedURL, identity: changedURL, sessionToken: token,
            revision: 13, status: .pending, deliveryRevision: 5, attempt: 2,
            retryable: false, claimed: true
        )
        let staleEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([stale], sessionToken: token, liveToken: token, revision: stale.revision),
            normalize: normalize
        )
        expect(staleEffects.isEmpty && state.rows.count == 2 &&
               state.rows.first(where: { $0.id == duplicate.id })?.deliveryRevision == 6,
               "terminal high-water: older poll after the newer replacement cannot rewind the installed row")

        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: token),
            normalize: normalize
        )
        expect(release.filter({ if case .releaseSession = $0 { return true }; return false }).count == 1 &&
               state.rows.first(where: { $0.id == duplicate.id })?.state == .installed,
               "terminal high-water: replacement ACK drains both rows before one release")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: token, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(token),
               "terminal high-water: confirmed replacement release seals the session")
    }

    private static func terminalPreviewOutcomesClaimBeforeAck() {
        let cases: [(String, AddonPairingReducer.ResolveOutcome, AddonPairingReducer.AckStatus)] = [
            ("already-installed", .alreadyInstalled(name: "Existing"), .installed),
            ("terminal-failure", .rejected(retryable: false, message: "blocked"), .failed)
        ]

        for (label, outcome, status) in cases {
            let token = "preview-\(label)-session"
            let d = delivery(id: "preview-\(label)-delivery", token: token, revision: 11)
            var state = AddonPairingReducer.State()
            let start = AddonPairingReducer.reduce(
                &state,
                .deliveries([d], sessionToken: token, liveToken: token, revision: d.revision),
                normalize: normalize
            )
            let ticket = start.compactMap { effect -> AddonPairingReducer.ResolveTicket? in
                if case let .resolveDurable(ticket, _) = effect { return ticket }
                return nil
            }.first
            expect(ticket != nil,
                   "terminal preview \(label): durable resolve carries a delivery/revision/identity ticket")
            guard let ticket else { continue }

            let preview = AddonPairingReducer.reduce(
                &state,
                .resolvedDurable(ticket: ticket, outcome: outcome),
                normalize: normalize
            )
            let initialAck = preview.compactMap { effect -> (String, Int, Int, Int, String, Bool)? in
                if case let .ack(deliveryID, _, ackStatus, _, _, attempt, deliveryRevision, revision,
                                 retryable, mutationID, requiresClaim) = effect,
                   ackStatus == status, !retryable {
                    return (deliveryID, attempt, deliveryRevision, revision, mutationID, requiresClaim)
                }
                return nil
            }.first
            expect(initialAck?.0 == d.id && initialAck?.1 == d.attempt &&
                   initialAck?.2 == d.deliveryRevision && initialAck?.3 == d.revision &&
                   initialAck?.5 == true && state.pendingAcks[d.id]?.requiresClaim == true,
                   "terminal preview \(label): durable outcome queues an ACK behind a live claim")
            guard let initialAck else { continue }

            let claimed = AddonPairingReducer.reduce(
                &state,
                .ackClaimFinished(deliveryID: d.id, token: token,
                                  authoritySession: token, authorityGeneration: 0,
                                  attempt: 1, deliveryRevision: 1,
                                  mutationID: initialAck.4, success: true),
                normalize: normalize
            )
            let claimedPending = state.pendingAcks[d.id]
            expect(claimed.isEmpty && claimedPending?.attempt == 1 &&
                   claimedPending?.deliveryRevision == 1 && claimedPending?.revision == d.revision &&
                   claimedPending?.mutationID == initialAck.4 && claimedPending?.requiresClaim == false,
                   "terminal preview \(label): ACK uses the exact attempt/revision returned by claim")
            guard let claimedPending else { continue }

            _ = AddonPairingReducer.reduce(
                &state,
                .ackFinished(deliveryID: d.id, token: token, status: status,
                             authoritySession: token, authorityGeneration: 0,
                             attempt: claimedPending.attempt, deliveryRevision: claimedPending.deliveryRevision,
                             revision: claimedPending.revision, retryable: false,
                             mutationID: claimedPending.mutationID, success: true),
                normalize: normalize
            )
            expect(state.pendingAcks[d.id] == nil && state.rows.first?.acked == status &&
                   state.acknowledgedDeliveryRevisions[d.id] == 1,
                   "terminal preview \(label): successful ACK commits the durable terminal result")

            let release = AddonPairingReducer.reduce(
                &state,
                .sessionClosed(sessionToken: token),
                normalize: normalize
            )
            expect(release.filter({ if case .releaseSession = $0 { return true }; return false }).count == 1,
                   "terminal preview \(label): release drains after the claimed terminal ACK")
        }
    }

    private static func initialPreviewClaimFailureAtZeroRequeues() {
        let token = "preview-zero-claim-session"
        let d = delivery(id: "preview-zero-claim-delivery", token: token, revision: 12)
        var state = AddonPairingReducer.State()
        let start = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: token, liveToken: token, revision: d.revision),
            normalize: normalize
        )
        guard let ticket = start.compactMap({ effect -> AddonPairingReducer.ResolveTicket? in
            if case let .resolveDurable(ticket, _) = effect { return ticket }
            return nil
        }).first else {
            expect(false, "claim attempt zero: terminal preview starts with a durable resolve ticket")
            return
        }

        let preview = AddonPairingReducer.reduce(
            &state,
            .resolvedDurable(ticket: ticket, outcome: .alreadyInstalled(name: "Existing")),
            normalize: normalize
        )
        let initialMutationID = preview.compactMap { effect -> String? in
            if case let .ack(deliveryID, _, status, _, _, attempt, deliveryRevision, revision,
                             retryable, mutationID, requiresClaim) = effect,
               deliveryID == d.id, status == .installed, !retryable,
               attempt == 0, deliveryRevision == 0, revision == d.revision, requiresClaim {
                return mutationID
            }
            return nil
        }.first
        expect(initialMutationID != nil && state.pendingAcks[d.id]?.attempt == 0 &&
               state.pendingAcks[d.id]?.deliveryRevision == 0,
               "claim attempt zero: fresh terminal preview queues an exact initial tuple behind claim")
        guard let initialMutationID else { return }

        let failure = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: d.id, token: token,
                              authoritySession: token, authorityGeneration: 0,
                              attempt: 0, deliveryRevision: 0,
                              mutationID: initialMutationID, success: false),
            normalize: normalize
        )
        let pendingAfterFailure = state.pendingAcks[d.id]
        expect(failure == [.poll(token: token, authoritySession: token, authorityGeneration: 0)] &&
               pendingAfterFailure?.requiresClaim == true &&
               pendingAfterFailure?.dispatched == false &&
               pendingAfterFailure?.awaitingPoll == true &&
               pendingAfterFailure?.attempt == 0 && pendingAfterFailure?.deliveryRevision == 0 &&
               pendingAfterFailure?.revision == d.revision &&
               state.rows.first(where: { $0.id == d.id })?.identity == d.identity &&
               state.rows.first(where: { $0.id == d.id })?.state == .installed,
               "claim attempt zero: nil claim becomes poll-retryable without losing row or tuple authority")

        let sameTuplePoll = AddonPairingReducer.Delivery(
            id: d.id, url: d.url, identity: d.identity, sessionToken: token,
            revision: d.revision, status: .pending, deliveryRevision: 0, attempt: 0,
            retryable: false, claimed: false
        )
        let requeued = AddonPairingReducer.reduce(
            &state,
            .deliveries([sameTuplePoll], sessionToken: token, liveToken: token, revision: d.revision),
            normalize: normalize
        )
        let retryAck = requeued.compactMap { effect -> (Int, Int, Int, String, Bool)? in
            if case let .ack(deliveryID, _, status, _, _, attempt, deliveryRevision, revision,
                             retryable, mutationID, requiresClaim) = effect,
               deliveryID == d.id, status == .installed, !retryable {
                return (attempt, deliveryRevision, revision, mutationID, requiresClaim)
            }
            return nil
        }.first
        expect(retryAck?.0 == 0 && retryAck?.1 == 0 && retryAck?.2 == d.revision &&
               retryAck?.3 != initialMutationID && retryAck?.4 == true &&
               state.pendingAcks[d.id]?.dispatched == true &&
               state.pendingAcks[d.id]?.awaitingPoll == false &&
               state.rows.first(where: { $0.id == d.id })?.identity == d.identity,
               "claim attempt zero: same-tuple poll requeues claim without inventing attempt or delivery revision")

        let closed = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: token),
            normalize: normalize
        )
        expect(closed.isEmpty && !state.isSessionReleased(token),
               "claim attempt zero: closed-session drain waits for the requeued claim and cannot release early")
        guard let retryAck else { return }

        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: d.id, token: token,
                              authoritySession: token, authorityGeneration: 0,
                              attempt: 1, deliveryRevision: 1,
                              mutationID: retryAck.3, success: true),
            normalize: normalize
        )
        let claimed = state.pendingAcks[d.id]
        expect(claimed?.attempt == 1 && claimed?.deliveryRevision == 1 &&
               claimed?.revision == d.revision && claimed?.mutationID == retryAck.3 &&
               claimed?.requiresClaim == false && claimed?.dispatched == true,
               "claim attempt zero: fresh claim supplies the only valid ACK attempt and revision")
        guard let claimed else { return }

        let ackResult = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: token, status: .installed,
                         authoritySession: token, authorityGeneration: 0,
                         attempt: claimed.attempt, deliveryRevision: claimed.deliveryRevision,
                         revision: claimed.revision, retryable: false,
                         mutationID: claimed.mutationID, success: true),
            normalize: normalize
        )
        let release = ackResult.compactMap { effect -> (String, Int)? in
            if case let .releaseSession(_, _, authorityGeneration, mutationID) = effect {
                return (mutationID, authorityGeneration)
            }
            return nil
        }.first
        expect(release != nil && state.pendingAcks[d.id] == nil &&
               state.rows.first(where: { $0.id == d.id })?.acked == .installed &&
               state.acknowledgedDeliveryRevisions[d.id] == 1,
               "claim attempt zero: exact successful ACK drains the terminal preview")
        guard release != nil else { return }
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: token, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(token),
               "claim attempt zero: fresh claim and exact ACK complete one confirmed release")
    }

    private static func lateResolveCompletionsAreFencedAcrossReplacement() {
        let cases: [(String, AddonPairingReducer.ResolveOutcome)] = [
            ("already-installed", .alreadyInstalled(name: "Old A")),
            ("terminal-failure", .rejected(retryable: false, message: "Old A failed"))
        ]

        for (label, oldOutcome) in cases {
            let token = "late-resolve-\(label)-session"
            let a = delivery(id: "late-resolve-\(label)-delivery", token: token, revision: 7)
            var state = AddonPairingReducer.State()
            let started = AddonPairingReducer.reduce(
                &state,
                .deliveries([a], sessionToken: token, liveToken: token, revision: a.revision),
                normalize: normalize
            )
            let oldTicket = started.compactMap { effect -> AddonPairingReducer.ResolveTicket? in
                if case let .resolveDurable(ticket, _) = effect { return ticket }
                return nil
            }.first
            guard let oldTicket else {
                expect(false, "late resolve \(label): initial delivery exposes a resolve ticket")
                continue
            }

            let bURL = "https://late-\(label)-replacement.example/manifest.json"
            let b = AddonPairingReducer.Delivery(
                id: a.id, url: bURL, identity: bURL, sessionToken: token,
                revision: 8, status: .pending, deliveryRevision: 1, attempt: 0,
                retryable: false, claimed: false
            )
            let replacement = AddonPairingReducer.reduce(
                &state,
                .deliveries([b], sessionToken: token, liveToken: token, revision: b.revision),
                normalize: normalize
            )
            let newTicket = replacement.compactMap { effect -> AddonPairingReducer.ResolveTicket? in
                if case let .resolveDurable(ticket, _) = effect { return ticket }
                return nil
            }.first
            expect(newTicket != nil && state.rows.first(where: { $0.id == a.id })?.identity == bURL,
                   "late resolve \(label): replacement installs a new exact identity ticket")
            guard let newTicket else { continue }

            let beforeLateResult = state
            let late = AddonPairingReducer.reduce(
                &state,
                .resolvedDurable(ticket: oldTicket, outcome: oldOutcome),
                normalize: normalize
            )
            expect(late.isEmpty && state == beforeLateResult && state.pendingAcks[a.id] == nil,
                   "late resolve \(label): old URL completion cannot mutate the newer row or ACK it")

            let legacyLate = AddonPairingReducer.reduce(
                &state,
                .resolved(rowId: a.id, outcome: oldOutcome),
                normalize: normalize
            )
            expect(legacyLate.isEmpty && state == beforeLateResult,
                   "late resolve \(label): row-only durable completion is rejected as an unfenced result")

            let current = AddonPairingReducer.reduce(
                &state,
                .resolvedDurable(ticket: newTicket, outcome: .ready(name: "New B")),
                normalize: normalize
            )
            expect(current.contains(where: { if case let .claim(deliveryID, _, deliveryRevision, _, _) = $0 {
                return deliveryID == a.id && deliveryRevision == 1
            }; return false }),
                   "late resolve \(label): the current replacement ticket remains actionable")
        }
    }

    private static func staleGenerationPollConvergesToCurrentAuthority() {
        let staleBody = Data("{\"ok\":false,\"error\":\"stale_generation\",\"generation\":4,\"proto\":2}".utf8)
        let current = AddonPairingClient.parseStaleGenerationResponse(staleBody, statusCode: 409)
        expect(current == 4, "stale poll: bounded structured 409 exposes the current generation")

        let wrongProto = Data("{\"ok\":false,\"error\":\"stale_generation\",\"generation\":4,\"proto\":1}".utf8)
        let oversized = Data(repeating: 0x20, count: AddonPairingProtocol.maxResponseBytes + 1)
        expect(AddonPairingClient.parseStaleGenerationResponse(wrongProto, statusCode: 409) == nil &&
               AddonPairingClient.parseStaleGenerationResponse(staleBody, statusCode: 200) == nil &&
               AddonPairingClient.parseStaleGenerationResponse(oversized, statusCode: 409) == nil,
               "stale poll: malformed, wrong-status, and oversized recovery bodies fail closed")

        let oldAuthority = AddonPairingClient.Authority(id: "stale-poll-authority", generation: 1)
        let recovered = AddonPairingClient.authorityForStaleGeneration(oldAuthority, currentGeneration: current ?? 0)
        expect(recovered == AddonPairingClient.Authority(id: oldAuthority.id, generation: 4),
               "stale poll: recovery adopts the relay authority and can converge on the next poll")
    }

    private static func closedReopenPollConvergesThroughRelease() {
        let oldAuthority = AddonPairingClient.Authority(id: "closed-reopen-authority", generation: 1)
        let stale = AddonPairingClient.pollTransition(
            result: .staleGeneration(2),
            authority: oldAuthority
        )
        let recoveredAuthority: AddonPairingClient.Authority
        if case let .stale(authority) = stale {
            recoveredAuthority = authority
        } else {
            recoveredAuthority = AddonPairingClient.Authority(id: "invalid", generation: 0)
        }
        expect(recoveredAuthority == AddonPairingClient.Authority(id: oldAuthority.id, generation: 2),
               "closed reopen: stale poll exposes the exact next authority instead of entering a sleep-only loop")

        let d = delivery(id: "closed-reopen-delivery", token: "closed-reopen-session", revision: 7)
        var state = AddonPairingReducer.State()
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: oldAuthority.id, generation: oldAuthority.generation),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: oldAuthority.id,
                           authorityGeneration: oldAuthority.generation,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let oldAck = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        expect(oldAck.contains(where: { if case .ack = $0 { return true }; return false }),
               "closed reopen: the pre-reopen install result remains pending for authoritative recovery")
        _ = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: d.sessionToken),
            normalize: normalize
        )

        let remote = AddonPairingClient.Poll(
            manifests: [AddonPairingClient.IncomingManifest(
                deliveryId: d.id, url: d.url, addedAtMs: 1_700_000_000_000,
                status: "pending", attempt: 1, deliveryRevision: 2,
                retryable: false, claimed: false
            )],
            expiresAtMs: 1_700_000_600_000,
            closed: false,
            rev: 8,
            generation: 2
        )
        let current = AddonPairingClient.pollTransition(
            result: .ok(remote),
            authority: recoveredAuthority
        )
        let currentAuthority: AddonPairingClient.Authority
        if case let .current(_, authority) = current {
            currentAuthority = authority
        } else {
            currentAuthority = AddonPairingClient.Authority(id: "invalid", generation: 0)
        }
        expect(currentAuthority == recoveredAuthority,
               "closed reopen: the next poll accepts the reopened generation")

        _ = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: currentAuthority.id, generation: currentAuthority.generation),
            normalize: normalize
        )
        let rebaseEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        // The explicit poll below carries the reopened revision/authority tuple.
        let exact = AddonPairingReducer.Delivery(
            id: d.id, url: d.url, identity: d.identity, sessionToken: d.sessionToken,
            revision: remote.rev, status: .pending, deliveryRevision: 2, attempt: 1, claimed: false
        )
        let exactEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([exact], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: remote.rev),
            normalize: normalize
        )
        let rebased = (rebaseEffects + exactEffects).compactMap { effect -> (Int, Int, Int, String)? in
            if case let .ack(_, _, _, _, _, attempt, deliveryRevision, revision, _, mutationID, requiresClaim) = effect,
               requiresClaim { return (attempt, deliveryRevision, revision, mutationID) }
            return nil
        }.last
        guard let rebased else {
            expect(false, "closed reopen: poll rebases the pending ACK to the exact reopened tuple")
            return
        }
        expect(rebased.0 == 1 && rebased.1 == 2 && rebased.2 == remote.rev &&
               state.pendingAcks[d.id]?.requiresClaim == true,
               "closed reopen: poll rebases the pending ACK to the exact reopened tuple")

        _ = AddonPairingReducer.reduce(
            &state,
            .ackClaimFinished(deliveryID: d.id, token: d.sessionToken,
                              authoritySession: currentAuthority.id,
                              authorityGeneration: currentAuthority.generation,
                              attempt: 2, deliveryRevision: 3,
                              mutationID: rebased.3, success: true),
            normalize: normalize
        )
        let drained = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .installed,
                         authoritySession: currentAuthority.id,
                         authorityGeneration: currentAuthority.generation,
                         attempt: 2, deliveryRevision: 3, revision: remote.rev,
                         retryable: false, mutationID: rebased.3, success: true),
            normalize: normalize
        )
        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: d.sessionToken),
            normalize: normalize
        )
        expect(drained.contains(where: { if case .releaseSession = $0 { return true }; return false }) &&
               release.isEmpty && state.pendingAcks[d.id] == nil,
               "closed reopen: recovered installed ACK drains before release")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: d.sessionToken, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(d.sessionToken),
               "closed reopen: confirmed release seals the converged session")
    }

    private static func lateLifecycleResultsAfterStopAreFenced() {
        for phase in ["saved poll", "reopen", "create"] {
            var stateMutations = 0
            var persistenceWrites = 0
            var taskStarts = 0
            let accepted = AddonPairingClient.canApplyLifecycleResult(
                expectedGeneration: 7,
                currentGeneration: 8,
                taskIsCancelled: false
            )
            if accepted {
                stateMutations += 1
                persistenceWrites += 1
                taskStarts += 1
            }
            expect(!accepted && stateMutations == 0 && persistenceWrites == 0 && taskStarts == 0,
                   "stop fence: late noncancellable \(phase) result performs no state, persistence, or task mutation")
        }

        let canceled = AddonPairingClient.canApplyLifecycleResult(
            expectedGeneration: 7,
            currentGeneration: 7,
            taskIsCancelled: true
        )
        expect(!canceled, "stop fence: canceled lifecycle result is rejected without generation drift")
    }

    private static func reopenRebasesPendingAcknowledgementAndFencesStaleAuthority() {
        func pendingAcknowledgement() -> (AddonPairingReducer.State, AddonPairingReducer.Delivery, String) {
            var state = AddonPairingReducer.State()
            let d = delivery(id: "reopen-delivery", token: "reopen-session", revision: 7)
            _ = AddonPairingReducer.reduce(
                &state,
                .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
                normalize: normalize
            )
            _ = AddonPairingReducer.reduce(
                &state,
                .authorityChanged(session: "old-authority", generation: 1),
                normalize: normalize
            )
            _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
            _ = AddonPairingReducer.reduce(
                &state,
                .claimFinished(rowId: d.id, authoritySession: "old-authority", authorityGeneration: 1,
                               attempt: 1, deliveryRevision: 1, success: true),
                normalize: normalize
            )
            let ackEffects = AddonPairingReducer.reduce(
                &state,
                .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .installed),
                normalize: normalize
            )
            let mutationID = ackEffects.compactMap { effect -> String? in
                if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
                return nil
            }.first ?? ""
            return (state, d, mutationID)
        }

        var state: AddonPairingReducer.State
        let original: AddonPairingReducer.Delivery
        let oldMutationID: String
        (state, original, oldMutationID) = pendingAcknowledgement()
        let reopened = AddonPairingReducer.Delivery(
            id: original.id,
            url: original.url,
            identity: original.identity,
            sessionToken: original.sessionToken,
            revision: 8,
            status: .pending,
            deliveryRevision: 2,
            attempt: 1,
            claimed: false
        )
        let rebasedEffects = AddonPairingReducer.reduce(
            &state,
            .deliveries([reopened], sessionToken: original.sessionToken, liveToken: original.sessionToken, revision: 8),
            normalize: normalize
        )
        let rebased = rebasedEffects.compactMap { effect -> (Int, Int, Int, String, Bool)? in
            if case let .ack(_, _, _, _, _, attempt, deliveryRevision, revision, _, mutationID, requiresClaim) = effect {
                return (attempt, deliveryRevision, revision, mutationID, requiresClaim)
            }
            return nil
        }.first
        expect(rebased?.0 == 1 && rebased?.1 == 2 && rebased?.2 == 8 &&
               rebased?.4 == true && rebased?.3 != oldMutationID &&
               state.pendingAcks[original.id]?.requiresClaim == true,
               "reopen: a higher same-URL delivery revision rebases the pending ACK and requires a fresh claim")

        let stale = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: original.id, token: original.sessionToken, status: .installed,
                         authoritySession: "old-authority", authorityGeneration: 1,
                         attempt: 1, deliveryRevision: 1, revision: 7, retryable: false,
                         mutationID: oldMutationID, success: true),
            normalize: normalize
        )
        expect(stale.isEmpty && state.rows[0].acked == nil && state.pendingAcks[original.id]?.mutationID != oldMutationID,
               "reopen: stale authority cannot publish the old ACK after rebasing")

        if let rebased {
            _ = AddonPairingReducer.reduce(
                &state,
                .ackClaimFinished(deliveryID: original.id, token: original.sessionToken,
                                  authoritySession: "old-authority", authorityGeneration: 1,
                                  attempt: 2, deliveryRevision: 3, mutationID: rebased.3, success: true),
                normalize: normalize
            )
            _ = AddonPairingReducer.reduce(
                &state,
                .ackFinished(deliveryID: original.id, token: original.sessionToken, status: .installed,
                             authoritySession: "old-authority", authorityGeneration: 1,
                             attempt: 2, deliveryRevision: 3, revision: 8, retryable: false,
                             mutationID: rebased.3, success: true),
                normalize: normalize
            )
        }
        let release = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: original.sessionToken),
            normalize: normalize
        )
        expect(release.contains(where: { if case .releaseSession = $0 { return true }; return false }) &&
               state.pendingAcks[original.id] == nil,
               "reopen: a rebased ACK drains before release is emitted")
        _ = AddonPairingReducer.reduce(
            &state,
            .releaseFinished(sessionToken: original.sessionToken, success: true),
            normalize: normalize
        )
        expect(state.isSessionReleased(original.sessionToken),
               "reopen: confirmed release seals the resumed session")

        var contested: AddonPairingReducer.State
        let contestedDelivery: AddonPairingReducer.Delivery
        let contestedMutationID: String
        (contested, contestedDelivery, contestedMutationID) = pendingAcknowledgement()
        let ownedByOther = AddonPairingReducer.Delivery(
            id: contestedDelivery.id,
            url: contestedDelivery.url,
            identity: contestedDelivery.identity,
            sessionToken: contestedDelivery.sessionToken,
            revision: 8,
            status: .pending,
            deliveryRevision: 2,
            attempt: 1,
            claimed: true
        )
        let fenced = AddonPairingReducer.reduce(
            &contested,
            .deliveries([ownedByOther], sessionToken: contestedDelivery.sessionToken,
                        liveToken: contestedDelivery.sessionToken, revision: 8),
            normalize: normalize
        )
        expect(fenced.contains(where: { if case let .ack(rowID, _, _, _, _, _, deliveryRevision, revision, _, _, requiresClaim) = $0 {
                   return rowID == contestedDelivery.id && deliveryRevision == 2 && revision == 8 && requiresClaim
               }; return false }) && contested.rows[0].state == .installed &&
               contested.pendingAcks[contestedDelivery.id] != nil,
               "reopen: another authority's claim fences the local result and requires a fresh claim")
        _ = AddonPairingReducer.reduce(
            &contested,
            .ackFinished(deliveryID: contestedDelivery.id, token: contestedDelivery.sessionToken, status: .installed,
                         authoritySession: "old-authority", authorityGeneration: 1,
                         attempt: 1, deliveryRevision: 1, revision: 7, retryable: false,
                         mutationID: contestedMutationID, success: true),
            normalize: normalize
        )
        expect(contested.rows[0].acked == nil,
               "reopen: stale completion cannot publish while a competing claim is fenced")
    }

    private static func hostileRedirectIsRevalidated() async {
        let start = URL(string: "https://public.example/manifest.json")!
        let target = AddonURLGuard.redirectTarget(from: start, location: "http://127.0.0.1/manifest.json")
        expect(target != nil, "redirect: relative/absolute Location is parsed")
        if let target {
            let rejection = await AddonURLGuard.validate(target)
            expect(rejection == .privateAddress,
                   "redirect: private redirect target is rejected before a second fetch")
        }
    }

    private static func userinfoIsRejected() async {
        let hostile = URL(string: "https://user:pass@public.example/manifest.json#secret")!
        let rejection = await AddonURLGuard.validate(hostile)
        expect(rejection == .invalidScheme,
               "redirect: userinfo and fragments are rejected before a manifest fetch")
    }

    private static func httpsSchemeIsRequiredByFetchGuard() async {
        let http = URL(string: "http://8.8.8.8/manifest.json")!
        expect(await AddonURLGuard.validate(http) == .invalidScheme,
               "manifest fetch: public HTTP URLs are rejected to match the relay contract")
    }

    private static func streamedBodyCapIsBounded() {
        let cap = AddonURLGuard.maxManifestBytes
        expect(AddonURLGuard.canAcceptBody(currentBytes: cap - 1, incomingBytes: 1),
               "body cap: exact maximum body is accepted")
        expect(!AddonURLGuard.canAcceptBody(currentBytes: cap, incomingBytes: 1),
               "body cap: streamed byte beyond maximum is rejected")
        expect(!AddonURLGuard.canAcceptBody(currentBytes: 0, incomingBytes: cap + 1),
               "body cap: one oversized chunk is rejected without buffering")
    }

    private static func protocolResponseCapIsBounded() {
        let cap = AddonPairingProtocol.maxResponseBytes
        expect(AddonPairingProtocol.canAcceptResponse(currentBytes: cap - 1, incomingBytes: 1),
               "poll body cap: exact maximum response is accepted")
        expect(!AddonPairingProtocol.canAcceptResponse(currentBytes: cap, incomingBytes: 1),
               "poll body cap: streamed byte beyond maximum is rejected")
        expect(!AddonPairingProtocol.canAcceptResponse(currentBytes: 0, incomingBytes: cap + 1),
               "poll body cap: oversized response chunk is rejected")
        expect(AddonPairingProtocol.canAcceptManifestCount(AddonPairingProtocol.maxManifests) &&
               !AddonPairingProtocol.canAcceptManifestCount(AddonPairingProtocol.maxManifests + 1),
               "poll manifest cap: relay-sized lists are bounded before reducer ingest")
    }

    private static func bodySignatureBindsAcknowledgement() {
        let url = URL(string: "https://add.vortx.tv/pair/ack")!
        var first = URLRequest(url: url)
        first.httpMethod = "POST"
        first.httpBody = Data("{\"mid\":\"one\"}".utf8)
        VortXEdgeAuth.signIncludingBody(&first)

        var second = URLRequest(url: url)
        second.httpMethod = "POST"
        second.httpBody = Data("{\"mid\":\"two\"}".utf8)
        VortXEdgeAuth.signIncludingBody(&second)

        expect(first.value(forHTTPHeaderField: "X-VX-Body") != second.value(forHTTPHeaderField: "X-VX-Body"),
               "ack auth: body digest changes with the acknowledgement body")
        expect(first.value(forHTTPHeaderField: "X-VX-Sig") != second.value(forHTTPHeaderField: "X-VX-Sig"),
               "ack auth: HMAC changes with the acknowledgement body")
        expect(AddonPairingClient.newMutationId() != AddonPairingClient.newMutationId(),
               "ack replay: every acknowledgement gets a fresh mutation id")
    }

    private static func pathlessProtocolFixtureIsExact() {
        let token = "abcdefghijklmnopqrstuv12"
        let authority = AddonPairingClient.Authority(id: "tv-authority-1", generation: 3)
        let poll = AddonPairingClient.makePollRequest(token: token, authority: authority)
        expect(poll?.url?.path == "/pair/poll" && !(poll?.url?.absoluteString.contains(token) ?? true),
               "protocol: poll carries no bearer token in its URL path or query")
        expect(AddonPairingClient.makePollRequest(
                   token: token,
                   authority: AddonPairingClient.Authority(id: "bad authority", generation: 3)
               ) == nil &&
               AddonPairingClient.makePollRequest(
                   token: token,
                   authority: AddonPairingClient.Authority(id: "tv-authority-1", generation: 0)
               ) == nil,
               "protocol: poll rejects malformed or uninitialized authority")
        if let poll, let body = poll.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            expect(Set(object.keys) == ["generation", "proto", "session", "token"] && object["token"] as? String == token &&
                   object["session"] as? String == authority.id && object["generation"] as? Int == authority.generation &&
                   object["proto"] as? Int == AddonPairingProtocol.version,
                   "protocol: poll body uses the centralized exact field set")
            expect(poll.value(forHTTPHeaderField: "X-VX-Body") != nil &&
                   poll.value(forHTTPHeaderField: "X-VX-Sig") != nil,
                   "protocol: poll HMAC binds the exact body bytes")
        } else {
            expect(false, "protocol: poll body decodes")
            expect(false, "protocol: poll HMAC binds the exact body bytes")
        }

        let delivery = AddonPairingClient.DeliveryAck(deliveryId: "delivery-1", status: "installed", attempt: 4,
                                                      deliveryRevision: 9, retryable: false)
        let claim = AddonPairingClient.makeClaimRequest(
            token: token,
            authority: authority,
            deliveryIDs: [delivery.deliveryId],
            deliveryRevision: delivery.deliveryRevision,
            mutationID: "claim-mutation-1"
        )
        expect(claim?.url?.path == "/pair/claim" && !(claim?.url?.absoluteString.contains(token) ?? true),
               "protocol: claim is pathless and token-free in URL material")
        let ack = AddonPairingClient.makeAckRequest(
            token: token,
            authority: authority,
            deliveries: [delivery],
            mutationID: "ack-mutation-1"
        )
        expect(ack?.url?.path == "/pair/ack" && !(ack?.url?.absoluteString.contains(token) ?? true),
               "protocol: ack is pathless and token-free in URL material")
        if let ack, let body = ack.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let acks = object["acks"] as? [[String: Any]], let first = acks.first {
            expect(Set(object.keys) == ["generation", "mutationId", "nonce", "proto", "session", "token", "acks"] &&
                   object["token"] as? String == token && object["session"] as? String == authority.id &&
                   object["generation"] as? Int == authority.generation && object["nonce"] as? String == "ack-mutation-1" &&
                   object["mutationId"] as? String == "ack-mutation-1" &&
                   first["id"] as? String == delivery.deliveryId && first["status"] as? String == "installed" &&
                   first["attempt"] as? Int == delivery.attempt && first["deliveryRev"] as? Int == delivery.deliveryRevision &&
                   first["retryable"] as? Bool == delivery.retryable,
                   "protocol: ack uses the canonical nonce/authority/attempt body fields")
        } else {
            expect(false, "protocol: ack body uses the canonical nonce/authority/attempt body fields")
        }

        let reopen = AddonPairingClient.makeReopenRequest(
            token: token,
            authority: authority,
            mutationID: "reopen-mutation-1"
        )
        expect(reopen?.url?.path == "/pair/reopen" && !(reopen?.url?.absoluteString.contains(token) ?? true),
               "protocol: reopen is pathless and token-free in URL material")
        if let reopen, let body = reopen.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            expect(Set(object.keys) == ["generation", "mutationId", "nonce", "proto", "session", "token"] &&
                   object["token"] as? String == token && object["session"] as? String == authority.id &&
                   object["generation"] as? Int == authority.generation &&
                   object["mutationId"] as? String == "reopen-mutation-1" &&
                   object["nonce"] as? String == "reopen-mutation-1" &&
                   object["proto"] as? Int == AddonPairingProtocol.version,
                   "protocol: reopen carries the exact generation-bound mutation body")
        } else {
            expect(false, "protocol: reopen body uses the canonical fields")
        }

        let release = AddonPairingClient.makeReleaseRequest(
            token: token,
            authority: authority,
            mutationID: "release-mutation-1"
        )
        expect(release?.url?.path == "/pair/release" && !(release?.url?.absoluteString.contains(token) ?? true),
               "protocol: release is pathless and token-free in URL material")
        if let release, let body = release.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            expect(Set(object.keys) == ["generation", "mutationId", "nonce", "proto", "session", "token"] &&
                   object["token"] as? String == token && object["session"] as? String == authority.id &&
                   object["generation"] as? Int == authority.generation &&
                   object["mutationId"] as? String == "release-mutation-1" &&
                   object["nonce"] as? String == "release-mutation-1" &&
                   object["proto"] as? Int == AddonPairingProtocol.version,
                   "protocol: release carries the exact generation-bound mutation body")
        } else {
            expect(false, "protocol: release body uses the canonical fields")
        }
    }

    private static func ackCommitsOnlyAfterNetworkSuccessAndRequeues() {
        var state = AddonPairingReducer.State()
        let d = delivery()
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: d.sessionToken, authorityGeneration: 0,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let ackEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        expect(ackEffects.contains(where: { if case .ack = $0 { return true }; return false }) &&
               state.rows[0].acked == nil && state.acknowledgedDeliveryRevisions[d.id] == nil,
               "ack: local install does not commit relay acknowledgement before network success")
        let firstMutationID = ackEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""

        let failed = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .installed,
                         authoritySession: d.sessionToken, authorityGeneration: 0,
                         attempt: 1, deliveryRevision: 1, revision: d.revision, retryable: false,
                         mutationID: firstMutationID, success: false),
            normalize: normalize
        )
        expect(failed.isEmpty && state.pendingAcks[d.id] != nil && state.isInFlight(sessionToken: d.sessionToken),
               "ack: transport failure retains a durable pending acknowledgement and keeps draining")

        let retry = AddonPairingReducer.reduce(
            &state,
            .retryPendingAck(deliveryID: d.id),
            normalize: normalize
        )
        expect(retry.contains(where: { if case .ack = $0 { return true }; return false }),
               "ack: failed acknowledgement is explicitly re-enqueued")
        let retryMutationID = retry.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""

        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .installed,
                         authoritySession: d.sessionToken, authorityGeneration: 0,
                         attempt: 1, deliveryRevision: 1, revision: d.revision, retryable: false,
                         mutationID: retryMutationID, success: false),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: d.sessionToken),
            normalize: normalize
        )
        let closedRetry = AddonPairingReducer.reduce(
            &state,
            .retryPendingWork(sessionToken: d.sessionToken),
            normalize: normalize
        )
        expect(closedRetry.contains(where: { if case .ack = $0 { return true }; return false }),
               "ack: closed-session polling re-enqueues an unconfirmed acknowledgement")
        let closedRetryMutationID = closedRetry.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""

        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .installed,
                         authoritySession: d.sessionToken, authorityGeneration: 0,
                         attempt: 1, deliveryRevision: 1, revision: d.revision, retryable: false,
                         mutationID: closedRetryMutationID, success: true),
            normalize: normalize
        )
        expect(state.rows[0].acked == .installed && state.acknowledgedDeliveryRevisions[d.id] != nil &&
               state.pendingAcks[d.id] == nil,
               "ack: only a successful network response commits terminal acknowledgement state")
    }

    private static func retryableFailureRetainsTheSession() {
        var state = AddonPairingReducer.State()
        let d = delivery(token: "retryable-session")
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: d.sessionToken, authorityGeneration: 0,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let failure = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1,
                                    outcome: .failedWithRetry(retryable: true, message: "offline")),
            normalize: normalize
        )
        let retryableMutationID = failure.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        expect(!failure.isEmpty && state.retryableFailures.contains(d.id) &&
               state.pendingAcks[d.id]?.retryable == true &&
               state.rows[0].state == .failed("offline"),
               "retryable failure: row remains actionable while relay ACK clears the claim")
        _ = AddonPairingReducer.reduce(
            &state,
            .ackFinished(deliveryID: d.id, token: d.sessionToken, status: .failed,
                         authoritySession: d.sessionToken, authorityGeneration: 0,
                         attempt: 1, deliveryRevision: 1, revision: d.revision, retryable: true,
                         mutationID: retryableMutationID, success: true),
            normalize: normalize
        )
        expect(state.pendingAcks[d.id] == nil && state.retryableFailures.contains(d.id),
               "retryable failure: accepted retryable ACK does not make the row terminal")
        let closed = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: d.sessionToken),
            normalize: normalize
        )
        expect(closed.isEmpty && !state.isSessionReleased(d.sessionToken),
               "retryable failure: close cannot release a session with unresolved work")
    }

    private static func resumeRequeuesCanceledDurableWork() {
        var state = AddonPairingReducer.State()
        let d = delivery(token: "resume-session")
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: "old-authority", authorityGeneration: 0,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        let resume = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: "new-authority", generation: 1),
            normalize: normalize
        )
        expect(state.rows[0].state == .resolving &&
               resume.contains(where: { if case let .resolveDurable(ticket, _) = $0 { return ticket.rowID == d.id }; return false }),
               "restart: canceled in-flight durable work is re-resolved under a fresh authority")
    }

    private static func resumeRequeuesPendingAcknowledgement() {
        var state = AddonPairingReducer.State()
        let d = delivery(token: "ack-resume-session")
        _ = AddonPairingReducer.reduce(
            &state,
            .deliveries([d], sessionToken: d.sessionToken, liveToken: d.sessionToken, revision: d.revision),
            normalize: normalize
        )
        _ = reduceDurableResolved(&state, rowID: d.id, outcome: .ready(name: "Example"))
        _ = AddonPairingReducer.reduce(
            &state,
            .claimFinished(rowId: d.id, authoritySession: "old-authority", authorityGeneration: 0,
                           attempt: 1, deliveryRevision: 1, success: true),
            normalize: normalize
        )
        _ = AddonPairingReducer.reduce(
            &state,
            .sessionClosed(sessionToken: d.sessionToken),
            normalize: normalize
        )
        let ackEffects = AddonPairingReducer.reduce(
            &state,
            .installFinishedAttempt(rowId: d.id, attempt: 1, outcome: .installed),
            normalize: normalize
        )
        let originalMutationID = ackEffects.compactMap { effect -> String? in
            if case let .ack(_, _, _, _, _, _, _, _, _, mutationID, _) = effect { return mutationID }
            return nil
        }.first ?? ""
        let resumed = AddonPairingReducer.reduce(
            &state,
            .authorityChanged(session: "new-authority", generation: 1),
            normalize: normalize
        )
        let resumedMutationID = resumed.compactMap { effect -> String? in
            if case let .ack(_, _, _, authoritySession, authorityGeneration, _, _, _, _, mutationID, _) = effect {
                return authoritySession == "new-authority" && authorityGeneration == 1 ? mutationID : nil
            }
            return nil
        }.first
        expect(state.pendingAcks[d.id]?.authoritySession == "new-authority" &&
               state.pendingAcks[d.id]?.authorityGeneration == 1 &&
               resumedMutationID != nil && resumedMutationID != originalMutationID &&
               !state.isSessionReleased(d.sessionToken),
               "restart: pending acknowledgement is re-enqueued under a fresh authority")
    }
}
