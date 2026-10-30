package com.vortx.android.xperience

import com.vortx.android.sync.NativeXperienceProfileGateway
import java.util.UUID
import java.util.ArrayDeque
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/** UNRUN standalone source controls. Real Store + real Namespace/Collections; this deliberately
 * synthetic gateway is NOT native, complete-account budget, cloud, observer, network or UI proof. */
internal object XperienceImportStoreSourceControls {
    private val actor = "00000000-0000-0000-0000-000000000001"
    private val namespace = UUID.fromString("10000000-0000-4000-8000-000000000001")
    private val otherNamespace = UUID.fromString("10000000-0000-4000-8000-000000000002")
    private fun document() = XperienceCollections.parse("""[{"id":"collection","title":"Synthetic","futureRaw":{"exact":18446744073709551615},"folders":[{"id":"folder","title":"Folder","sources":[{"provider":"addon","addonId":"fixture.addon","type":"movie","catalogId":"popular","url":"https://untrusted.fixture.invalid/manifest.json"}]}]}]""".toByteArray(Charsets.UTF_8))
    private fun event(value: ByteArray, clock: Int = 1): ByteArray =
        ("{\"clock\":$clock,\"actor\":\"$actor\",\"value\":" + String(value, Charsets.UTF_8) + "}").toByteArray(Charsets.UTF_8)
    private fun savedRegister(id: UUID = namespace): ByteArray {
        val owned = XperienceImportNamespace.append(document(), "Original", id).value()
        // Synthetic ORIGINAL evidence with an unknown value member, not a decoded DTO reconstruction.
        val raw = String(owned, Charsets.UTF_8).dropLast(1) + ",\"futureSaved\":{\"exact\":18446744073709551615}}"
        return event(raw.toByteArray(Charsets.UTF_8))
    }

    private class SyntheticGateway : NativeXperienceProfileGateway {
        class Target(val epoch: Int, override val profileId: String) : NativeXperienceProfileGateway.Target {
            override val accountId = "synthetic-account"
            var retired = false
        }
        class Snapshot(override val target: Target, fields: Map<String, ByteArray>, private val readError: Error? = null) : NativeXperienceProfileGateway.Snapshot {
            private val fields = fields.mapValues { it.value.copyOf() }
            override fun registers(): Map<String, ByteArray> {
                readError?.let { throw it }
                return fields.mapValues { it.value.copyOf() }
            }
        }
        var epoch = 1
        var profile = "profile-a"
        val profiles: MutableMap<String, MutableMap<String, ByteArray>> =
            mutableMapOf("profile-a" to linkedMapOf(), "profile-b" to linkedMapOf())
        var captures = 0
        var writes = 0
        var deletions = 0
        var commits = 0
        var cancellations = 0
        var retirements = 0
        var captureFailure = false
        var writeFailure = false
        var throwCapture = false
        var throwPublication = false
        var throwWrite = false
        var publicationError: Error? = null
        var beforePublication: (() -> Unit)? = null
        var onRetire: (() -> Unit)? = null
        var registerReadError: Error? = null
        var currentError: Error? = null
        var currentErrorAt: Int? = null
        var currentChecks = 0
        var ignoreCancellation = false
        var returnLateSnapshotOnly = false
        val started = CompletableDeferred<Unit>()
        var release: CompletableDeferred<Unit>? = null
        val targetsUsed = ArrayList<Target>()

        override fun captureXperienceProfile(): Result<NativeXperienceProfileGateway.Snapshot> {
            captures++
            if (throwCapture) throw IllegalStateException("synthetic capture exception")
            if (captureFailure) return Result.failure(IllegalStateException("synthetic unavailable"))
            val target = Target(epoch, profile)
            return Result.success(Snapshot(target, profiles.getValue(target.profileId), registerReadError))
        }
        override fun xperienceSnapshot(target: NativeXperienceProfileGateway.Target): Result<NativeXperienceProfileGateway.Snapshot> {
            val original = target as Target
            return if (xperienceTargetIsCurrent(original)) Result.success(Snapshot(original, profiles.getValue(original.profileId)))
            else Result.failure(IllegalStateException("synthetic stale"))
        }
        override fun xperienceTargetIsCurrent(target: NativeXperienceProfileGateway.Target): Boolean {
            currentChecks++
            if (currentChecks == currentErrorAt) currentError?.let { throw it }
            return (target as Target).let { !it.retired && it.epoch == epoch && it.profileId == profile }
        }
        override fun publishXperienceIfCurrent(snapshot: NativeXperienceProfileGateway.Snapshot, publication: () -> Unit): Boolean {
            beforePublication?.invoke()
            publicationError?.let { throw it }
            if (throwPublication) throw IllegalStateException("synthetic publication exception")
            val original = snapshot.target as Target
            if (!xperienceTargetIsCurrent(original)) return false
            val observed = snapshot.registers()
            val current = profiles.getValue(original.profileId)
            if (observed.keys != current.keys || observed.any { (field, bytes) -> !bytes.contentEquals(current[field]) }) return false
            publication()
            return true
        }
        override fun retireXperienceTarget(target: NativeXperienceProfileGateway.Target) {
            val original = target as Target
            if (!original.retired) { original.retired = true; retirements++; onRetire?.invoke() }
        }
        override suspend fun writeXperience(target: NativeXperienceProfileGateway.Target,
            edit: XperienceImportNamespace.Edit): Result<NativeXperienceProfileGateway.Snapshot> {
            writes++
            if (throwWrite) throw IllegalStateException("synthetic write exception")
            return persist(target as Target, edit, deleting = false)
        }
        override suspend fun deleteXperience(target: NativeXperienceProfileGateway.Target,
            saved: XperienceImportNamespace.Saved): Result<NativeXperienceProfileGateway.Snapshot> {
            deletions++
            val original = XperienceImportNamespace.read(saved.field, saved.register())
            return persist(target as Target, original.replacement(original.document, original.label, original.bindings), deleting = true)
        }
        private suspend fun persist(target: Target, edit: XperienceImportNamespace.Edit,
            deleting: Boolean): Result<NativeXperienceProfileGateway.Snapshot> {
            targetsUsed += target
            started.complete(Unit)
            try {
                val barrier = release
                if (barrier != null) {
                    if (ignoreCancellation) withContext(NonCancellable) { barrier.await() } else barrier.await()
                }
            } catch (cancelled: CancellationException) { cancellations++; throw cancelled }
            if (returnLateSnapshotOnly) return Result.success(Snapshot(target, profiles.getValue(target.profileId)))
            if (!xperienceTargetIsCurrent(target)) return Result.failure(IllegalStateException("synthetic original owner retired"))
            if (writeFailure) return Result.failure(IllegalStateException("synthetic unavailable"))
            val fields = profiles.getValue(target.profileId)
            if (!edit.baselineMatches(fields[edit.field])) {
                return Result.failure(XperienceCollections.Rejected(XperienceCollections.Failure.STALE_REGISTER))
            }
            fields[edit.field] = event(if (deleting) "null".toByteArray(Charsets.UTF_8) else edit.value(), commits + 2)
            commits++
            return Result.success(Snapshot(target, fields))
        }
    }

    private fun testScope() = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    /** Deterministic owned queue only: no thread, sleep, test framework or simulated native lane. */
    private class QueuedDispatcher : CoroutineDispatcher() {
        private val queue = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { queue.addLast(block) }
        val pending: Int get() = queue.size
        fun drain() {
            var steps = 0
            while (queue.isNotEmpty()) {
                check(++steps <= 1000) { "Synthetic dispatcher did not settle" }
                queue.removeFirst().run()
            }
        }
    }
    private fun ready(store: XperienceImportStore): XperienceImportStore.Opening {
        val opening = checkNotNull(store.open())
        check(store.state.value.phase == XperienceImportStore.Phase.READY)
        check(store.state.value.opening === opening)
        return opening
    }

    private suspend fun supportedReplaceAndRebindRetainRawUnknowns() {
        val gateway = SyntheticGateway()
        val field = XperienceImportNamespace.field(namespace)
        gateway.profiles.getValue("profile-a")[field] = savedRegister()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            ready(store)
            val handle = store.state.value.records.single().handle
            val detail = checkNotNull(store.detail(handle))
            val source = detail.document.collections.single().folders.single().sources.single()
            val mapping = XperienceImportNamespace.Binding("fixture.addon", "a".repeat(64))
            checkNotNull(store.rebind(handle, mapOf(source.semanticDigest to mapping))).join()
            check(store.state.value.phase == XperienceImportStore.Phase.LOCAL_ACCEPTED)
            check(store.state.value.opening == null && store.state.value.records.isEmpty())
            val raw = gateway.profiles.getValue("profile-a").getValue(field)
            check(String(raw, Charsets.UTF_8).contains("\"futureSaved\":{\"exact\":18446744073709551615}"))
            val saved = XperienceImportNamespace.read(field, raw)
            check(saved.document.raw().contentEquals(detail.document.raw()))
            check(saved.bindings[source.semanticDigest] == mapping)
            check(gateway.captures == 1 && gateway.commits == 1 && gateway.targetsUsed.single().retired)
            // A successful action does not upgrade old display handles into a fresh opening.
            check(store.delete(handle) == null && gateway.deletions == 0)
            ready(store)
            val next = store.state.value.records.single().handle
            checkNotNull(store.replace(next, document(), label = "Refreshed")).join()
            check(XperienceImportNamespace.read(field, gateway.profiles.getValue("profile-a").getValue(field)).label == "Refreshed")
            check(gateway.captures == 2 && gateway.commits == 2)
        } finally { store.close(); scope.cancel() }
    }

    private suspend fun unsupportedAndTombstoneRemainOccupiedReadOnly() {
        val gateway = SyntheticGateway()
        val future = XperienceImportNamespace.field(namespace)
        val tombstone = XperienceImportNamespace.field(otherNamespace)
        val futureRaw = event("""{"schemaVersion":2,"opaque":{"keep":18446744073709551615}}""".toByteArray(Charsets.UTF_8))
        val tombstoneRaw = event("null".toByteArray(Charsets.UTF_8))
        gateway.profiles.getValue("profile-a")[future] = futureRaw
        gateway.profiles.getValue("profile-a")[tombstone] = tombstoneRaw
        val supportedID = UUID.fromString("10000000-0000-4000-8000-000000000003")
        val supportedField = XperienceImportNamespace.field(supportedID)
        val supportedRaw = savedRegister(supportedID)
        gateway.profiles.getValue("profile-a")[supportedField] = supportedRaw
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            val opening = ready(store)
            check(store.state.value.records.size == 3 && store.state.value.records.count { it.editable } == 1)
            check(store.state.value.records.filter { !it.editable }.map { it.kind }.toSet() ==
                setOf(XperienceImportStore.RecordKind.READ_ONLY, XperienceImportStore.RecordKind.TOMBSTONE))
            check(store.detail(store.state.value.records.single { it.editable }.handle)?.label == "Original")
            val handle = store.state.value.records.first { !it.editable }.handle
            check(store.detail(handle) == null)
            checkNotNull(store.delete(handle)).join()
            check(store.state.value.failure == XperienceImportStore.Failure.READ_ONLY && gateway.deletions == 0)
            for (occupied in listOf(namespace, otherNamespace)) {
                checkNotNull(store.append(opening, document(), "No overwrite", occupied)).join()
                check(store.state.value.failure == XperienceImportStore.Failure.NAMESPACE_OCCUPIED)
            }
            check(gateway.writes == 0 && gateway.profiles.getValue("profile-a").getValue(future).contentEquals(futureRaw))
            check(gateway.profiles.getValue("profile-a").getValue(tombstone).contentEquals(tombstoneRaw))
            check(gateway.profiles.getValue("profile-a").getValue(supportedField).contentEquals(supportedRaw))
        } finally { store.close(); scope.cancel() }
    }

    private suspend fun ownerLostDuringCommitCannotPublishOrCaptureSuccessor() {
        val gateway = SyntheticGateway(); gateway.release = CompletableDeferred()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            val opening = ready(store)
            val job = checkNotNull(store.append(opening, document(), "Original"))
            gateway.started.await()
            gateway.epoch++ // Synthetic original auth/account generation retirement.
            gateway.release!!.complete(Unit)
            job.join()
            check(store.state.value.phase == XperienceImportStore.Phase.RETIRED)
            check(gateway.captures == 1 && gateway.commits == 0 && gateway.targetsUsed.single().epoch == 1)
        } finally { store.close(); scope.cancel() }
    }

    private suspend fun staleSavedCASDoesNotRebase() {
        val gateway = SyntheticGateway()
        gateway.release = CompletableDeferred()
        val field = XperienceImportNamespace.field(namespace)
        gateway.profiles.getValue("profile-a")[field] = savedRegister()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            ready(store)
            val handle = store.state.value.records.single().handle
            val job = checkNotNull(store.replace(handle, document(), label = "Stale draft"))
            gateway.started.await() // Saving gate passed the original snapshot; CAS changes while awaiting.
            val replacementByAnotherWriter = event(XperienceImportNamespace.append(document(), "External", namespace).value(), 9)
            gateway.profiles.getValue("profile-a")[field] = replacementByAnotherWriter
            gateway.release!!.complete(Unit)
            job.join()
            check(store.state.value.phase == XperienceImportStore.Phase.RETIRED)
            check(gateway.commits == 0 && gateway.captures == 1)
            check(gateway.profiles.getValue("profile-a").getValue(field).contentEquals(replacementByAnotherWriter))
        } finally { store.close(); scope.cancel() }
    }

    private suspend fun newerOpeningFencesLateCompletionAndOldHandle() {
        val gateway = SyntheticGateway()
        gateway.release = CompletableDeferred(); gateway.ignoreCancellation = true; gateway.returnLateSnapshotOnly = true
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            val original = ready(store)
            val job = checkNotNull(store.append(original, document(), "Old"))
            gateway.started.await()
            gateway.profile = "profile-b"
            val successor = ready(store)
            check(job.isCancelled && gateway.targetsUsed.single().retired)
            // A stale view cannot cancel or report an error into the newer opening.
            check(store.append(original, document(), "Wrong view") == null)
            check(store.state.value.opening === successor)
            gateway.release!!.complete(Unit)
            job.join()
            check(store.state.value.phase == XperienceImportStore.Phase.READY && store.state.value.opening === successor)
            check(gateway.captures == 2 && gateway.commits == 0 && gateway.targetsUsed.single().profileId == "profile-a")
        } finally { store.close(); scope.cancel() }
    }

    private suspend fun disposalCancelsActualOwnedChildAndRetiresTarget() {
        val gateway = SyntheticGateway(); gateway.release = CompletableDeferred()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        val opening = ready(store)
        val job = checkNotNull(store.append(opening, document(), "Cancelled"))
        gateway.started.await()
        store.close()
        job.join()
        check(job.isCancelled && gateway.cancellations == 1 && gateway.targetsUsed.single().retired)
        check(store.state.value.phase == XperienceImportStore.Phase.CLOSED && store.open() == null)
        check(gateway.commits == 0 && gateway.captures == 1)
        scope.cancel()
    }

    private suspend fun newActionCannotRebasePendingAction() {
        val gateway = SyntheticGateway(); gateway.release = CompletableDeferred()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            val opening = ready(store)
            val first = checkNotNull(store.append(opening, document(), "Pending"))
            gateway.started.await()
            check(store.append(opening, document(), "Do not rebase") == null)
            first.join()
            check(first.isCancelled && gateway.cancellations == 1 && gateway.targetsUsed.single().retired)
            check(store.state.value.phase == XperienceImportStore.Phase.RETIRED)
            check(store.state.value.failure == XperienceImportStore.Failure.SUPERSEDED)
            check(gateway.writes == 1 && gateway.commits == 0 && gateway.captures == 1)
        } finally { store.close(); scope.cancel() }
    }

    private suspend fun errorsAreBoundedAndDoNotRecapture() {
        val gateway = SyntheticGateway()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            val opening = ready(store)
            checkNotNull(store.append(opening, document(), "")).join() // Actual pure validation failure.
            check(store.state.value.phase == XperienceImportStore.Phase.ERROR && store.state.value.failure == XperienceImportStore.Failure.REJECTED)
            check(gateway.writes == 0 && gateway.captures == 1)
            gateway.writeFailure = true
            checkNotNull(store.append(opening, document(), "Retry same original" )).join()
            check(store.state.value.failure == XperienceImportStore.Failure.UNAVAILABLE)
            check(gateway.captures == 1 && gateway.commits == 0 && store.state.value.opening === opening)
            store.invalidate()
            check(store.state.value.phase == XperienceImportStore.Phase.RETIRED)
            check(store.append(opening, document(), "Retired") == null)
        } finally { store.close(); scope.cancel() }
        val unavailable = SyntheticGateway().also { it.captureFailure = true }
        val unavailableScope = testScope(); val unavailableStore = XperienceImportStore(unavailable, unavailableScope, Dispatchers.Unconfined)
        try {
            check(unavailableStore.open() == null && unavailableStore.state.value.failure == XperienceImportStore.Failure.UNAVAILABLE)
            check(unavailable.captures == 1)
        } finally { unavailableStore.close(); unavailableScope.cancel() }
    }

    private fun isolatedBatchKeepsLegacyReaderAndResourceDenial() {
        val valid = XperienceImportNamespace.field(namespace)
        val deleted = XperienceImportNamespace.field(otherNamespace)
        val future = XperienceImportNamespace.field(UUID.fromString("10000000-0000-4000-8000-000000000003"))
        val supportedAndDeleted = mapOf(valid to savedRegister(), deleted to event("null".toByteArray(Charsets.UTF_8)))
        val legacy = XperienceImportNamespace.readAll(supportedAndDeleted)
        check(legacy.size == 1 && legacy.single().field == valid) // Existing drop-tombstone behavior unchanged.
        val fields = supportedAndDeleted + (future to event("""{"schemaVersion":2,"opaque":"retain"}""".toByteArray(Charsets.UTF_8)))
        val isolated = XperienceImportNamespace.readIsolated(fields)
        check(isolated.size == 3)
        check(isolated.single { it.field == valid } is XperienceImportNamespace.Observation.Supported)
        check(isolated.single { it.field == deleted } is XperienceImportNamespace.Observation.Tombstone)
        check(isolated.single { it.field == future } is XperienceImportNamespace.Observation.ReadOnly)
        try {
            XperienceImportNamespace.readAll(fields)
            throw AssertionError("Legacy readAll unexpectedly softened an unsupported sibling")
        } catch (rejected: XperienceCollections.Rejected) {
            check(rejected.reason == XperienceCollections.Failure.UNSUPPORTED_SAVED_FORMAT)
        }
        // A genuine small retained-budget ceiling proves status-result reservation failure
        // is fatal for the batch. No 32MiB payload or simulated full-account budget is allocated.
        try {
            XperienceImportNamespace.readIsolated(mapOf(deleted to supportedAndDeleted.getValue(deleted)),
                XperienceImportNamespace.RetainedBudget(limit = 128, registerLimit = 128))
            throw AssertionError("Resource denial was swallowed as a read-only observation")
        } catch (rejected: XperienceCollections.Rejected) {
            check(rejected.reason == XperienceCollections.Failure.TOO_LARGE)
        }
    }

    private fun freshDetailRequiresOriginalSnapshotAdmission() {
        val gateway = SyntheticGateway()
        gateway.profiles.getValue("profile-a")[XperienceImportNamespace.field(namespace)] = savedRegister()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            ready(store)
            val handle = store.state.value.records.single().handle
            gateway.epoch++ // No fake observer notification: the original gateway gate must decide.
            check(store.detail(handle) == null)
            check(store.state.value.phase == XperienceImportStore.Phase.RETIRED && store.state.value.records.isEmpty())
            check(gateway.captures == 1 && gateway.commits == 0)
        } finally { store.close(); scope.cancel() }
    }

    private fun savingPublicationRequiresOriginalSnapshotAdmission() {
        val gateway = SyntheticGateway()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, Dispatchers.Unconfined)
        try {
            val opening = ready(store)
            val observed = ArrayList<XperienceImportStore.Phase>()
            gateway.beforePublication = { observed += store.state.value.phase }
            gateway.epoch++
            check(store.append(opening, document(), "Denied original owner") == null)
            check(observed == listOf(XperienceImportStore.Phase.READY))
            check(store.state.value.phase == XperienceImportStore.Phase.RETIRED && store.state.value.records.isEmpty())
            check(gateway.writes == 0 && gateway.captures == 1)
        } finally { store.close(); scope.cancel() }
    }

    private suspend fun ordinaryGatewayExceptionsCannotLeaveBusyAndErrorPropagates() {
        val captureGateway = SyntheticGateway().also { it.throwCapture = true }
        val captureScope = testScope(); val captureStore = XperienceImportStore(captureGateway, captureScope, Dispatchers.Unconfined)
        try {
            check(captureStore.open() == null)
            check(captureStore.state.value.phase == XperienceImportStore.Phase.ERROR &&
                captureStore.state.value.failure == XperienceImportStore.Failure.UNAVAILABLE)
        } finally { captureStore.close(); captureScope.cancel() }
        val publicationGateway = SyntheticGateway().also { it.throwPublication = true }
        val publicationScope = testScope(); val publicationStore = XperienceImportStore(publicationGateway, publicationScope, Dispatchers.Unconfined)
        try {
            publicationStore.open()
            check(publicationStore.state.value.phase == XperienceImportStore.Phase.RETIRED)
        } finally { publicationStore.close(); publicationScope.cancel() }
        val writeGateway = SyntheticGateway()
        val writeScope = testScope(); val writeStore = XperienceImportStore(writeGateway, writeScope, Dispatchers.Unconfined)
        try {
            val opening = ready(writeStore)
            writeGateway.throwWrite = true
            checkNotNull(writeStore.append(opening, document(), "Exception")).join()
            check(writeStore.state.value.phase == XperienceImportStore.Phase.ERROR &&
                writeStore.state.value.failure == XperienceImportStore.Failure.UNAVAILABLE)
            check(writeGateway.commits == 0 && writeGateway.captures == 1)
        } finally { writeStore.close(); writeScope.cancel() }
        val errorGateway = SyntheticGateway()
        errorGateway.profiles.getValue("profile-a")[XperienceImportNamespace.field(namespace)] = savedRegister()
        val errorScope = testScope(); val errorStore = XperienceImportStore(errorGateway, errorScope, Dispatchers.Unconfined)
        try {
            ready(errorStore)
            val original = AssertionError("synthetic Error, no OOM allocation")
            errorGateway.publicationError = original
            try {
                errorStore.detail(errorStore.state.value.records.single().handle)
                throw AssertionError("Error was swallowed")
            } catch (failure: AssertionError) { check(failure === original) }
        } finally { errorStore.close(); errorScope.cancel() }
    }

    private suspend fun queuedPreEntryAndInlineCancellationHaveNoOrphans() {
        val dispatcher = QueuedDispatcher()
        val gateway = SyntheticGateway()
        val scope = testScope(); val store = XperienceImportStore(gateway, scope, dispatcher)
        val parent = checkNotNull(scope.coroutineContext[Job])
        try {
            checkNotNull(store.open())
            check(store.state.value.phase == XperienceImportStore.Phase.LOADING && dispatcher.pending > 0)
            val lifetime = parent.children.single()
            val load = lifetime.children.single()
            load.cancel() // The queued load has not entered its try/finally body.
            dispatcher.drain(); check(load.isCompleted); load.join()
            check(load.isCancelled && load.isCompleted && lifetime.children.none())
            check(store.state.value.phase == XperienceImportStore.Phase.RETIRED && gateway.retirements == 1)

            val opening = checkNotNull(store.open())
            dispatcher.drain()
            check(store.state.value.phase == XperienceImportStore.Phase.READY)
            val write = checkNotNull(store.append(opening, document(), "Cancel before body"))
            check(store.state.value.phase == XperienceImportStore.Phase.SAVING && dispatcher.pending > 0)
            check(gateway.writes == 0)
            write.cancel() // Exact returned Job, cancelled before queued execute body entry.
            dispatcher.drain(); check(write.isCompleted); write.join()
            check(write.isCancelled && write.isCompleted && lifetime.children.none())
            check(store.state.value.phase == XperienceImportStore.Phase.RETIRED && store.state.value.opening == null)
            check(gateway.writes == 0 && gateway.commits == 0 && gateway.retirements == 2)

            val fresh = checkNotNull(store.open())
            dispatcher.drain()
            check(store.state.value.phase == XperienceImportStore.Phase.READY)
            val accepted = checkNotNull(store.append(fresh, document(), "Normal completion"))
            dispatcher.drain(); check(accepted.isCompleted); accepted.join()
            check(store.state.value.phase == XperienceImportStore.Phase.LOCAL_ACCEPTED)
            check(gateway.writes == 1 && gateway.commits == 1 && lifetime.children.none() && dispatcher.pending == 0)
            store.close(); dispatcher.drain()
            check(lifetime.isCompleted && parent.children.none() && dispatcher.pending == 0)
        } finally { store.close(); dispatcher.drain(); scope.cancel() }

        val inlineDispatcher = QueuedDispatcher()
        val inlineGateway = SyntheticGateway()
        val inlineScope = testScope(); val inlineStore = XperienceImportStore(inlineGateway, inlineScope, inlineDispatcher)
        var observer: Job? = null
        try {
            val opening = checkNotNull(inlineStore.open())
            val lifetime = checkNotNull(inlineScope.coroutineContext[Job]).children.single()
            inlineDispatcher.drain()
            var successor: XperienceImportStore.Opening? = null
            inlineGateway.onRetire = {
                inlineGateway.onRetire = null
                inlineGateway.profile = "profile-b"
                // This deliberately new opening is a lock-order probe: a retirement called
                // under the consumer monitor would be denied by Store's reentrant-read guard.
                successor = checkNotNull(inlineStore.open())
            }
            var appendReturned = false
            var cancelledInline = false
            observer = inlineScope.launch {
                inlineStore.state.collect { state ->
                    if (state.phase == XperienceImportStore.Phase.SAVING) {
                        cancelledInline = !appendReturned
                        lifetime.children.single().cancel() // Inline before this reserved lazy worker starts.
                    }
                }
            }
            inlineStore.append(opening, document(), "Inline cancel")
            appendReturned = true
            check(cancelledInline)
            inlineDispatcher.drain()
            check(successor != null && inlineStore.state.value.opening === successor)
            check(inlineStore.state.value.phase == XperienceImportStore.Phase.READY)
            check(inlineGateway.captures == 2 && inlineGateway.writes == 0 && inlineGateway.retirements == 1)
            check(lifetime.children.none() && inlineDispatcher.pending == 0)
        } finally { observer?.cancel(); inlineStore.close(); inlineDispatcher.drain(); inlineScope.cancel() }
    }

    private suspend fun escapingChildErrorPropagatesAndReleasesOwnedWorker() {
        for (duringLoad in listOf(true, false)) {
            val original = AssertionError("synthetic child Error; no OOM allocation")
            val observed = ArrayList<Throwable>()
            val handler = CoroutineExceptionHandler { _, failure -> observed += failure }
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined + handler)
            val dispatcher = QueuedDispatcher()
            val gateway = SyntheticGateway()
            if (duringLoad) gateway.registerReadError = original
            val store = XperienceImportStore(gateway, scope, dispatcher)
            try {
                val opening = checkNotNull(store.open())
                val lifetime = checkNotNull(scope.coroutineContext[Job]).children.single()
                val failed = if (duringLoad) {
                    lifetime.children.single()
                } else {
                    dispatcher.drain()
                    check(store.state.value.phase == XperienceImportStore.Phase.READY)
                    // Saving Snapshot admission performs the next current check; the actual
                    // queued execute child throws at its following check, BEFORE gateway write.
                    gateway.currentError = original
                    gateway.currentErrorAt = gateway.currentChecks + 2
                    checkNotNull(store.append(opening, document(), "Error before write"))
                }
                dispatcher.drain(); check(failed.isCompleted); failed.join()
                check(observed.size == 1 && observed.single() === original)
                check(store.state.value.phase == XperienceImportStore.Phase.RETIRED)
                check(store.state.value.opening == null && store.state.value.records.isEmpty())
                check(lifetime.children.none() && dispatcher.pending == 0)
                check(gateway.captures == 1 && gateway.writes == 0 && gateway.commits == 0 && gateway.retirements == 1)

                gateway.registerReadError = null; gateway.currentError = null; gateway.currentErrorAt = null
                gateway.profile = "profile-b"
                val successor = checkNotNull(store.open()) // Explicit new user opening, never an error retry.
                dispatcher.drain()
                check(store.state.value.phase == XperienceImportStore.Phase.READY && store.state.value.opening === successor)
                check(store.append(opening, document(), "Old failed opening") == null)
                dispatcher.drain()
                check(store.state.value.phase == XperienceImportStore.Phase.READY && store.state.value.opening === successor)
                check(gateway.captures == 2 && gateway.writes == 0 && lifetime.children.none())
            } finally { store.close(); dispatcher.drain(); scope.cancel() }
        }
    }

    @JvmStatic fun main(args: Array<String>) = runBlocking {
        require(args.isEmpty())
        supportedReplaceAndRebindRetainRawUnknowns()
        unsupportedAndTombstoneRemainOccupiedReadOnly()
        ownerLostDuringCommitCannotPublishOrCaptureSuccessor()
        staleSavedCASDoesNotRebase()
        newerOpeningFencesLateCompletionAndOldHandle()
        disposalCancelsActualOwnedChildAndRetiresTarget()
        newActionCannotRebasePendingAction()
        errorsAreBoundedAndDoNotRecapture()
        isolatedBatchKeepsLegacyReaderAndResourceDenial()
        freshDetailRequiresOriginalSnapshotAdmission()
        savingPublicationRequiresOriginalSnapshotAdmission()
        ordinaryGatewayExceptionsCannotLeaveBusyAndErrorPropagates()
        queuedPreEntryAndInlineCancellationHaveNoOrphans()
        escapingChildErrorPropagatesAndReleasesOwnedWorker()
        println("PASS actual Store source controls with synthetic gateway; no native/cloud/platform proof")
    }
}
