package com.vortx.android.ui.viewmodel

import com.vortx.android.engine.NativeXperienceCatalogGateway as Catalog
import com.vortx.android.engine.XperienceCatalogConsumerID
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.sync.NativeXperienceProfileGateway
import com.vortx.android.xperience.XperienceCollections
import com.vortx.android.xperience.XperienceAddonBinding
import com.vortx.android.xperience.XperienceImportNamespace
import java.io.ByteArrayInputStream
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/** UNRUN real controller + Store + pure domain; explicit synthetic catalog/profile boundaries.
 * No JNI, native reducer, installed-registry, auth, encryption, Android provider/device proof. */
internal object XperienceCollectionsCallerSourceControls {
    private val namespace = UUID.fromString("10000000-0000-4000-8000-000000000001")
    private val actor = "00000000-0000-0000-0000-000000000001"
    private fun bytes(title: String = "Original") = """[{"id":"c","title":"$title","future":{"exact":18446744073709551615},"folders":[{"id":"f","title":"Folder","sources":[{"provider":"addon","addonId":"fixture","type":"movie","catalogId":"popular","genre":"None"}]}]}]""".toByteArray()
    private fun event(value: ByteArray, clock: Int = 1) = ("{\"clock\":$clock,\"actor\":\"$actor\",\"value\":" + String(value, Charsets.UTF_8) + "}").toByteArray()
    private class Queue : CoroutineDispatcher() {
        val work = java.util.ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { work.addLast(block) }
        fun runOne() { check(work.isNotEmpty()); work.removeFirst().run() }
        fun drain() { var turns = 0; while (work.isNotEmpty()) { check(++turns < 10_000) { "Controlled queue did not settle" }; work.removeFirst().run() } }
    }
    private class Fixture : NativeXperienceProfileGateway, Catalog, AutoCloseable {
        class Target(override val accountId: String = "controlled", override val profileId: String = "a") : NativeXperienceProfileGateway.Target { var live = true }
        class Snapshot(override val target: Target, fields: Map<String, ByteArray>) : NativeXperienceProfileGateway.Snapshot {
            private val original = fields.mapValues { it.value.copyOf() }
            override fun registers() = original.mapValues { it.value.copyOf() }
        }
        class Stage(val epoch: Long) : Catalog.OpeningStage { var live = true; override fun close() { live = false } }
        class Lease(val snapshot: NativeXperienceProfileGateway.Snapshot, val saved: XperienceImportNamespace.Saved?, val epoch: Long) : Catalog.Lease {
            var live = true; var rawLive = true; override fun close() { live = false }
        }
        class Selection(val lease: Lease) : Catalog.Selection { var live = true; override fun close() { live = false } }
        val queue = Queue(); val parent = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val signals = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
        override val invalidations = signals
        val listeners = mutableListOf<() -> Unit>()
        var epoch = 1L; var stages = 0; var captures = 0; var nativeChecks = 0; var writes = 0; var loads = 0
        var nextStatus: Catalog.SourceStatus? = null
        var barrier: CompletableDeferred<Unit>? = null
        var ignoreCancellation = false
        var itemCount = 1
        val defaultBinding = XperienceImportNamespace.Binding("fixture", "a".repeat(64)) // Controlled installed mapping, not real registry proof.
        val choice = object : Catalog.Choice { override val label = "Controlled installed source" }
        val projectionDefaults = mutableListOf<Boolean>()
        val originalDocument = XperienceCollections.parse(bytes())
        val sourceKey = XperienceAddonBinding.key(originalDocument.collections.single().folders.single().sources.single())
        val fields = linkedMapOf(XperienceImportNamespace.field(namespace) to event(XperienceImportNamespace.append(originalDocument, "Saved", namespace, mapOf(sourceKey to defaultBinding)).value()))
        val leases = mutableListOf<Lease>()
        val vm = XperienceCollectionsViewModel(this, this, parent, queue, queue)
        override fun callerEpoch() = epoch
        override fun observeMetadataInvalidation(listener: () -> Unit): AutoCloseable { listeners += listener; return AutoCloseable { listeners.remove(listener) } }
        override fun stageOpening(originalEpoch: Long): Catalog.OpeningStage? { stages++; return Stage(originalEpoch).takeIf { originalEpoch == epoch } }
        override fun open(stage: Catalog.OpeningStage): Result<NativeXperienceProfileGateway.Snapshot> {
            captures++; val original = stage as Stage
            return if (original.live && original.epoch == epoch) captureXperienceProfile() else Result.failure(IllegalStateException("stale stage"))
        }
        override fun discard(snapshot: NativeXperienceProfileGateway.Snapshot) { retireXperienceTarget(snapshot.target) }
        override fun captureXperienceProfile(): Result<NativeXperienceProfileGateway.Snapshot> = Result.success(Snapshot(Target(), fields))
        override fun xperienceSnapshot(target: NativeXperienceProfileGateway.Target): Result<NativeXperienceProfileGateway.Snapshot> = Result.success(Snapshot(target as Target, fields))
        override fun xperienceTargetIsCurrent(target: NativeXperienceProfileGateway.Target) = (target as Target).live
        override fun publishXperienceIfCurrent(snapshot: NativeXperienceProfileGateway.Snapshot, publication: () -> Unit): Boolean {
            nativeChecks++
            if (!xperienceTargetIsCurrent(snapshot.target)) return false
            val before = snapshot.registers()
            try { if (before.keys != fields.keys || before.any { (field, raw) -> !raw.contentEquals(fields[field]) }) return false }
            finally { before.values.forEach { it.fill(0) } }
            publication(); return true
        }
        override fun retireXperienceTarget(target: NativeXperienceProfileGateway.Target) { (target as Target).live = false }
        override suspend fun writeXperience(target: NativeXperienceProfileGateway.Target, edit: XperienceImportNamespace.Edit): Result<NativeXperienceProfileGateway.Snapshot> {
            check(xperienceTargetIsCurrent(target)); check(edit.baselineMatches(fields[edit.field])); writes++
            fields[edit.field] = event(edit.value(), writes + 1)
            return xperienceSnapshot(target)
        }
        override suspend fun deleteXperience(target: NativeXperienceProfileGateway.Target, saved: XperienceImportNamespace.Saved): Result<NativeXperienceProfileGateway.Snapshot> {
            check(saved.register().contentEquals(fields[saved.field])); writes++; fields[saved.field] = event("null".toByteArray(), writes + 1)
            return xperienceSnapshot(target)
        }
        override fun capture(snapshot: NativeXperienceProfileGateway.Snapshot, saved: XperienceImportNamespace.Saved?): Result<Catalog.Lease> {
            check(publishXperienceIfCurrent(snapshot) {})
            return Result.success(Lease(snapshot, saved, epoch).also { leases += it })
        }
        override fun locallyCurrent(lease: Catalog.Lease) = (lease as Lease).let { it.live && it.rawLive && it.epoch == epoch }
        override fun isCurrent(lease: Catalog.Lease) = locallyCurrent(lease) && publishXperienceIfCurrent((lease as Lease).snapshot) {}
        override fun publish(lease: Catalog.Lease, publication: () -> Unit) = locallyCurrent(lease) && publishXperienceIfCurrent((lease as Lease).snapshot, publication)
        override fun preview(lease: Catalog.Lease, document: XperienceCollections.Document, label: String,
            existing: Map<String, XperienceImportNamespace.Binding>, choices: Map<String, Catalog.Choice?>,
            allowDefaults: Boolean): Result<Catalog.Preview> {
            check(isCurrent(lease)); projectionDefaults += allowDefaults
            val keys = document.collections.flatMap { it.folders }.flatMap { it.sources }.filter { it.isAddon }.map(XperienceAddonBinding::key)
            val bindings = existing.toMutableMap()
            if (allowDefaults) keys.filter { it !in choices && it !in bindings }.forEach { bindings[it] = defaultBinding }
            choices.forEach { (key, selected) -> if (selected == null) bindings.remove(key) else { check(selected === choice); bindings[key] = defaultBinding } }
            XperienceImportNamespace.append(document, label, bindings = bindings)
            val rows = keys.mapIndexed { index, key -> Catalog.BindingRow(key, index + 1, listOf(choice),
                choice.takeIf { key in bindings }, if (key in bindings) Catalog.SourceStatus.RESOLVED else Catalog.SourceStatus.MAPPING_UNAVAILABLE) }
            return Result.success(Catalog.Preview(rows, bindings.toMap()))
        }
        override fun select(lease: Catalog.Lease, collectionId: String, folderId: String, sourceIndex: Int): Result<Catalog.Selection> {
            check(isCurrent(lease)); checkNotNull((lease as Lease).saved).document.collections.single { it.id == collectionId }
                .folders.single { it.id == folderId }.sources[sourceIndex]
            return Result.success(Selection(lease))
        }
        override suspend fun load(selection: Catalog.Selection, consumer: XperienceCatalogConsumerID, skip: Int?): Result<Catalog.Outcome> {
            loads++
            val wait = barrier
            if (wait != null) { if (ignoreCancellation) withContext(NonCancellable) { wait.await() } else wait.await() }
            val selected = selection as Selection
            if (!selected.live || !isCurrent(selected.lease)) return Result.failure(IllegalStateException("old selection"))
            return Result.success(nextStatus?.let { Catalog.Outcome.Unresolved(it) } ?: Catalog.Outcome.Loaded(Catalog.Page(
                (1..itemCount).map { MetaItem("tt$it", MediaType.MOVIE, "Controlled $it") }, maxOf(5, itemCount), (skip ?: 0) + maxOf(5, itemCount), skip == null)))
        }
        fun ready() { vm.open(vm.route); check(captures == 0); queue.drain(); check(vm.state.value.phase == XperienceCollectionsViewModel.Phase.READY) }
        fun preview(): XperienceCollectionsViewModel.Preview { vm.previewPaste(vm.route, String(bytes())); queue.drain(); return checkNotNull(vm.state.value.preview) }
        fun browser(): XperienceCollectionsViewModel.Browser {
            vm.browse(vm.route, vm.state.value.records.single().handle); queue.drain()
            vm.openCollection(checkNotNull(vm.state.value.browser), "c"); queue.drain()
            vm.openFolder(checkNotNull(vm.state.value.browser), "f"); queue.drain()
            return checkNotNull(vm.state.value.browser)
        }
        fun changeRaw() { fields[fields.keys.single()] = event(XperienceImportNamespace.append(XperienceCollections.parse(bytes("Changed")), "Saved", namespace).value(), 9); leases.forEach { it.rawLive = false } }
        fun retireEpoch() { epoch++; listeners.toList().forEach { it() }; signals.tryEmit(Unit) }
        override fun close() {
            barrier?.complete(Unit)
            vm.javaClass.getDeclaredMethod("onCleared").apply { isAccessible = true }.invoke(vm)
            queue.drain(); check(listeners.isEmpty())
            parent.coroutineContext[Job]?.cancel(); fields.values.forEach { it.fill(0) }
        }
    }
    private fun originalOpeningStageAndRetiredRouteNeverRecapture() {
        Fixture().use { f ->
            f.vm.open(f.vm.route); check(f.stages == 1 && f.captures == 0)
            f.retireEpoch(); f.queue.drain()
            check(f.vm.state.value.phase == XperienceCollectionsViewModel.Phase.RETIRED)
            f.vm.open(f.vm.route); f.queue.drain(); check(f.stages == 1 && f.captures == 0)
        }
    }
    private fun originalStoreLoadTerminalRetiresCallerAfterWrapperHandoff() {
        Fixture().use { f ->
            f.vm.open(f.vm.route)
            f.queue.runOne() // Actual caller wrapper hands off to actual Store's separate lazy load.
            check(f.captures == 1 && f.vm.state.value.phase == XperienceCollectionsViewModel.Phase.LOADING)
            // Same-profile raw replacement before Store's original Snapshot publication.
            f.changeRaw()
            f.queue.drain()
            check(f.vm.state.value.phase == XperienceCollectionsViewModel.Phase.RETIRED)
            check(!f.vm.state.value.busy && f.vm.state.value.records.isEmpty())
            val captures = f.captures
            f.vm.open(f.vm.route); f.queue.drain(); check(f.captures == captures)
        }
        Fixture().use { f ->
            f.vm.open(f.vm.route); f.queue.runOne()
            f.vm.open(f.vm.route) // Explicit successor opening before the old lazy load runs.
            f.queue.drain()
            check(f.captures == 2 && f.vm.state.value.phase == XperienceCollectionsViewModel.Phase.READY)
            check(f.vm.state.value.records.size == 1) // Old terminal cannot retire the successor.
        }
    }
    private fun chooserOldNullDuplicateAndReadLimitAreOwned() {
        Fixture().use { f ->
            f.ready()
            val first = checkNotNull(f.vm.beginFileImport(f.vm.route)); val second = checkNotNull(f.vm.beginFileImport(f.vm.route))
            var opens = 0; var closes = 0
            f.vm.fileResult(first) { opens++; error("retired opener called") }; f.vm.cancelFileImport(first)
            f.vm.fileResult(second) { opens++; object : ByteArrayInputStream(bytes()) { override fun close() { closes++; super.close() } } }
            f.vm.fileResult(second) { opens++; error("duplicate opener called") }
            f.queue.drain(); check(opens == 1 && closes >= 1)
            val current = checkNotNull(f.vm.state.value.preview)
            f.vm.fileResult(first, null); check(f.vm.state.value.preview === current)
            val large = checkNotNull(f.vm.beginFileImport(f.vm.route))
            f.vm.fileResult(large) { ByteArrayInputStream(ByteArray(XperienceCollections.MAX_BYTES + 1) { ' '.code.toByte() }) }
            f.queue.drain(); check(f.vm.state.value.failure == XperienceCollectionsViewModel.Failure.TOO_LARGE)
        }
    }
    private fun retainedOriginalChooserClaimsOneLaunchAndNeverRestoresAuthority() {
        Fixture().use { f ->
            f.ready(); val original = checkNotNull(f.vm.beginFileImport(f.vm.route))
            check(f.vm.state.value.fileTicket === original && original.launcherKey.contains(original.id))
            check(f.vm.claimFileLaunch(original)); check(!f.vm.claimFileLaunch(original))
            // Controlled recreation reads retained state and registers this SAME key/ticket.
            val recreated = checkNotNull(f.vm.state.value.fileTicket)
            check(recreated === original && recreated.launcherKey == original.launcherKey)
            check(!f.vm.claimFileLaunch(recreated)) // No duplicate OS launch from a new presenter.
            val successor = checkNotNull(f.vm.beginFileImport(f.vm.route))
            check(f.vm.state.value.fileTicket === successor && successor.launcherKey != original.launcherKey)
            f.vm.fileResult(original, null); check(f.vm.state.value.fileTicket === successor)
            check(!f.vm.claimFileLaunch(original)); check(f.vm.claimFileLaunch(successor))
            f.vm.fileResult(successor) { ByteArrayInputStream(bytes()) }; f.queue.drain()
            check(f.vm.state.value.fileTicket == null && f.vm.state.value.preview != null)
        }
        Fixture().use { fresh -> check(fresh.vm.state.value.fileTicket == null) } // New VM has no restored ticket.
    }
    private fun explicitUnavailableSurvivesLabelStageAndConfirmation() {
        Fixture().use { f ->
            f.ready(); val initial = f.preview()
            check(f.projectionDefaults.last() && initial.bindings.single().status == Catalog.SourceStatus.RESOLVED)
            f.vm.chooseBinding(initial, f.sourceKey, null); f.queue.drain()
            val cleared = checkNotNull(f.vm.state.value.preview)
            check(!f.projectionDefaults.last() && cleared.bindings.single().status == Catalog.SourceStatus.MAPPING_UNAVAILABLE)
            f.vm.setLabel(cleared, "Local draft"); val labelled = checkNotNull(f.vm.state.value.preview)
            f.vm.stageAppend(labelled, "Confirmed unavailable"); f.queue.drain()
            check(!f.projectionDefaults.last())
            f.vm.confirm(checkNotNull(f.vm.state.value.confirmation)); f.queue.drain()
            check(f.writes == 1 && f.vm.state.value.phase == XperienceCollectionsViewModel.Phase.LOCAL_ACCEPTED)
            val appended = f.fields.entries.single { it.key != XperienceImportNamespace.field(namespace) }
            val saved = XperienceImportNamespace.read(appended.key, appended.value)
            check(saved.bindings.isEmpty() && saved.label == "Confirmed unavailable")
        }
    }
    private fun originalPreviewRefreshAndConfirmationUseOriginalSaved() {
        Fixture().use { f ->
            f.ready(); val handle = f.vm.state.value.records.single().handle
            f.vm.review(f.vm.route, handle); f.queue.drain(); val before = checkNotNull(f.vm.state.value.preview)
            val ticket = checkNotNull(f.vm.beginFileImport(f.vm.route, before))
            f.vm.fileResult(ticket) { ByteArrayInputStream(bytes("Replacement")) }; f.queue.drain()
            val replacement = checkNotNull(f.vm.state.value.preview); check(replacement.replacing === handle)
            check(replacement.document.collections.single().title == "Replacement")
            f.vm.stageReplace(before); check(f.vm.state.value.confirmation == null)
            val checks = f.nativeChecks
            f.vm.setLabel(replacement, "Local draft"); check(f.nativeChecks == checks) // No per-key native work.
            val draft = checkNotNull(f.vm.state.value.preview)
            f.vm.stageReplace(draft, "Confirmed label"); f.queue.drain(); val confirm = checkNotNull(f.vm.state.value.confirmation)
            f.vm.confirm(confirm); f.queue.drain()
            check(f.writes == 1 && f.vm.state.value.phase == XperienceCollectionsViewModel.Phase.LOCAL_ACCEPTED)
            val saved = XperienceImportNamespace.read(XperienceImportNamespace.field(namespace), f.fields.values.single())
            check(saved.label == "Confirmed label" && saved.document.collections.single().title == "Replacement")
            check(String(saved.document.raw()).contains("18446744073709551615"))
            f.vm.confirm(confirm); f.queue.drain(); check(f.writes == 1)
        }
    }
    private fun everyUnresolvedSelectionRetiresOldRequestAndCleanup() {
        Fixture().use { f ->
            f.ready(); val sources = f.browser(); f.barrier = CompletableDeferred(); f.ignoreCancellation = true
            f.vm.openSource(sources, 0); f.queue.drain(); val old = checkNotNull(f.vm.state.value.browser)
            f.vm.openSource(old, -1); f.queue.drain(); check(f.vm.state.value.browser?.failure != null)
            f.barrier!!.complete(Unit); f.queue.drain(); check(f.vm.state.value.browser?.items?.isEmpty() == true)
            f.barrier = null
            for (status in listOf(Catalog.SourceStatus.MISSING, Catalog.SourceStatus.AMBIGUOUS, Catalog.SourceStatus.MAPPING_UNAVAILABLE, Catalog.SourceStatus.UNSUPPORTED, Catalog.SourceStatus.INVALID_REGISTRY)) {
                f.nextStatus = status
                val current = checkNotNull(f.vm.state.value.browser)
                f.vm.openSource(current, 0); f.queue.drain(); check(f.vm.state.value.browser?.status == status)
                check(f.vm.state.value.browser?.loading == false)
            }
            var routed = false
            check(!f.vm.openItem(old, MetaItem("tt1", MediaType.MOVIE, "Controlled")) { routed = true }); check(!routed)
        }
    }
    private fun rawObservationRevokesCheapTitleAndOldBrowserGestures() {
        Fixture().use { f ->
            f.ready(); val sources = f.browser(); f.itemCount = 2_001; f.vm.openSource(sources, 0); f.queue.drain()
            val page = checkNotNull(f.vm.state.value.browser); val item = page.items.first(); val checks = f.nativeChecks
            check(page.items.size == 2_000 && page.limited && !page.hasMore)
            f.changeRaw(); var routed = false
            check(!f.vm.openItem(page, item) { routed = true }); check(!routed && f.nativeChecks == checks)
            val loads = f.loads; f.vm.loadMoreCatalog(page); f.queue.drain(); check(f.loads == loads)
            f.vm.stop(f.vm.route); f.vm.previewPaste(f.vm.route, String(bytes())); f.queue.drain()
            check(f.vm.state.value.phase == XperienceCollectionsViewModel.Phase.RETIRED)
        }
        Fixture().use { f ->
            f.ready(); val sources = f.browser(); f.vm.openSource(sources, 0); f.queue.drain()
            val page = checkNotNull(f.vm.state.value.browser)
            val monitor = f.vm.javaClass.getDeclaredField("lock").apply { isAccessible = true }.get(f.vm)
            check(f.vm.openItem(page, page.items.single()) {
                check(!Thread.holdsLock(monitor))
                f.vm.stop(f.vm.route) // Reentrant navigation disposal must drain outside monitor.
            })
            check(f.vm.state.value.phase == XperienceCollectionsViewModel.Phase.RETIRED)
        }
    }
    @JvmStatic fun main(args: Array<String>) = runBlocking {
        require(args.isEmpty())
        originalOpeningStageAndRetiredRouteNeverRecapture()
        originalStoreLoadTerminalRetiresCallerAfterWrapperHandoff()
        chooserOldNullDuplicateAndReadLimitAreOwned()
        retainedOriginalChooserClaimsOneLaunchAndNeverRestoresAuthority()
        explicitUnavailableSurvivesLabelStageAndConfirmation()
        originalPreviewRefreshAndConfirmationUseOriginalSaved()
        everyUnresolvedSelectionRetiresOldRequestAndCleanup()
        rawObservationRevokesCheapTitleAndOldBrowserGestures()
        println("PASS controlled caller/Store bodies only; no native, installed-registry, server, provider or device proof")
    }
}
