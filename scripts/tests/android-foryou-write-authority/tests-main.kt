@file:JvmName("ForYouWriteAuthorityPacket")
package com.vortx.android.engine

import android.content.SharedPreferences
import com.vortx.android.foryou.*
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.sync.LocalLibraryMutationAuthority
import com.vortx.android.sync.VortXSyncManager
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.coroutines.CoroutineContext
import org.json.JSONObject

private class QueueDispatcher : CoroutineDispatcher() {
    private val work = ConcurrentLinkedQueue<Runnable>()
    override fun dispatch(context: CoroutineContext, block: Runnable) { work.add(block) }
    fun drain() { while (true) (work.poll() ?: return).run() }
}
private class Prefs : SharedPreferences {
    var raw = "{}"; var commits = 0; var reads=0; var beforeRead:(()->Unit)?=null
    override fun getString(key: String, fallback: String?):String { reads++; beforeRead?.invoke(); return raw }
    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private var pending = raw
        override fun putString(key: String, value: String): SharedPreferences.Editor { pending = value; return this }
        override fun commit(): Boolean { raw = pending; commits++; return true }
    }
}
private class NativeCase {
    val accounts = NativeAccountCoordinator()
    val original = accounts.session().apply { seed() }
    val queue = QueueDispatcher()
    val access = NativeForYouAccess(accounts, queue)
    val snapshot = access.capture().getOrThrow()
    val observed = ForYouObservedField.capture(snapshot.fields, ForYouInterests.FIELD)
    var live = true
    suspend fun queued(change: () -> Unit): Result<Unit> = coroutineScope {
        val call = async(start = CoroutineStart.UNDISPATCHED) {
            access.write(snapshot.owner, ForYouInterests.FIELD, observed, ForYouInterests(genres=listOf("drama")).toJson()) { live }
        }
        change(); queue.drain(); call.await()
    }
}
private suspend fun originalNativeSchedules() {
    suspend fun rejected(change: NativeCase.() -> Unit) {
        val f = NativeCase(); val before = f.original.fields.toString()
        check(f.queued { f.change() }.isFailure)
        check(f.original.commits == 0 && f.original.fields.toString() == before)
        check(f.accounts.session().commits == 0)
    }
    rejected {
        val successor = VortxNativeSession().apply { seed() }
        val account = SessionOwnerSnapshot.Account("account-A",2) // same UID/profile, new auth generation
        accounts.authenticated = account; accounts.mounted.set(NativeAccountCoordinator.Mounted(successor,account))
    }
    rejected { // same auth generation, replacement Session/mount with matching profile ID
        val old = accounts.mounted.get()
        accounts.mounted.set(NativeAccountCoordinator.Mounted(VortxNativeSession().apply { seed() },old.account))
    }
    rejected { // same Session+account, replaced exact Mounted instance
        val old = accounts.mounted.get(); accounts.mounted.set(NativeAccountCoordinator.Mounted(old.session,old.account))
    }
    rejected { original.owner = original.owner.copy(profileID="B",revision=2); original.owner=original.owner.copy(profileID="A",revision=3) }
    rejected { live = false } // dialog replaced before coroutine's IO entry
    val stale = NativeCase(); val edited = JSONObject(stale.original.fields.getJSONObject(ForYouInterests.FIELD).toString()).put("clock",2)
    check(stale.queued { stale.original.fields.put(ForYouInterests.FIELD,edited) }.isFailure)
    check(stale.original.commits==0 && stale.original.fields.getJSONObject(ForYouInterests.FIELD).getInt("clock")==2)
    val tombstone = NativeCase()
    check(tombstone.queued { tombstone.original.seed(value=JSONObject.NULL,clock=2) }.isFailure)
    check(tombstone.original.commits==0 && tombstone.original.fields.getJSONObject(ForYouInterests.FIELD).isNull("value"))
    val absent = NativeCase(); val absentObservation = ForYouObservedField.capture(JSONObject(),ForYouInterests.FIELD)
    check(!absentObservation.matches(absent.original.fields,ForYouInterests.FIELD))
    val success = NativeCase(); val unrelated="forYou.collection.00000000-0000-0000-0000-000000000001"
    // Direct synthetic Session field injection proves adapter collaborator conservation only.
    // Production Session owner retirement on host DTO edits remains a separate actual-Session gate.
    success.original.seed(unrelated,JSONObject().put("unknown",7))
    check(success.queued { success.original.seed(unrelated,JSONObject().put("unknown",8),2) }.isSuccess)
    check(success.original.fields.getJSONObject(unrelated).getJSONObject("value").getInt("unknown")==8)
    check(!success.original.isTyped && success.original.genericDispatches==1 && success.original.lastField==ForYouInterests.FIELD)
    val refresh = NativeCase()
    check(refresh.queued { refresh.accounts.changes.value += 1; refresh.original.updates.value += 1 }.isSuccess)
    check(refresh.original.commits==1) // read-publication stamp changes do not retire command authority
    val checkpointRejected = NativeCase(); checkpointRejected.original.rejectCandidate=true
    val old=checkpointRejected.original.fields.toString()
    check(checkpointRejected.queued {}.isFailure && checkpointRejected.original.commits==0 && checkpointRejected.original.fields.toString()==old)
    val cancelled = NativeCase()
    coroutineScope {
        val call=async(start=CoroutineStart.UNDISPATCHED) { cancelled.access.write(cancelled.snapshot.owner,ForYouInterests.FIELD,cancelled.observed,ForYouInterests().toJson()) { true } }
        call.cancel(); cancelled.queue.drain(); runCatching { call.await() }
    }
    check(cancelled.original.commits==0)
    val cancellationAtDurability = NativeCase()
    coroutineScope {
        val call=async(start=CoroutineStart.UNDISPATCHED) {
            cancellationAtDurability.access.write(cancellationAtDurability.snapshot.owner,ForYouInterests.FIELD,cancellationAtDurability.observed,ForYouInterests().toJson()) { true }
        }
        cancellationAtDurability.original.beforeDurability={call.cancel()}
        cancellationAtDurability.queue.drain(); runCatching { call.await() }
    }
    check(cancellationAtDurability.original.commits==0)
    val late = NativeCase(); late.original.beforeDurability={late.live=false}
    check(late.queued {}.isFailure && late.original.commits==0)
    println("PASS actual_native_adapter_original_account_mount_profile_ABA_register_tombstone_unrelated_generic_cancellation_final_admission")
}

private suspend fun actualStoreSchedules() {
    val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
    try {
        val prefs=Prefs(); var active="A"; var signed=false; var listener:()->Unit={}
        val manager=VortXSyncManager()
        val queue=QueueDispatcher()
        val store=ForYouStore(prefs,{active},{signed},{listener=it},scope,Dispatchers.Unconfined,queue,
            captureLocalAuthority={ manager.captureLocalLibraryMutationAuthority()?.let { authority ->
                LocalLibraryMutationAuthority(authority.identity) { action -> authority.admit { !signed && action() } }
            } })
        queue.drain(); check(store.state.value.ready)
        val open=ForYouEditSession(store.state.value)
        val one=store.prepare(open,ForYouInterests(genres=listOf("drama"))).getOrThrow()
        signed=true; manager.operations.generation++ // delayed observer: captured auth admission still rejects
        val rejected=scope.async(start=CoroutineStart.UNDISPATCHED) { store.execute(one) }
        queue.drain(); check(rejected.await().isFailure && prefs.commits==0)
        signed=false; manager.operations.generation++; listener(); queue.drain()
        val aba=ForYouEditSession(store.state.value)
        val before=store.prepare(aba,ForYouInterests()).getOrThrow()
        active="B"; listener(); active="A"; listener(); queue.drain()
        check(store.execute(before).isFailure && prefs.commits==0)
        val original=ForYouEditSession(store.state.value)
        val intent=store.prepare(original,ForYouInterests(genres=listOf("scifi"))).getOrThrow()
        original.close() // replacement before scope.launch; retains original draft/value
        check(store.execute(intent).isFailure && prefs.commits==0)
        val current=ForYouEditSession(store.state.value)
        val save=store.prepare(current,ForYouInterests(genres=listOf("drama"))).getOrThrow()
        // A concurrent distinct local field/profile is retained by the fresh all-read + one-field merge.
        prefs.raw=JSONObject().put("A",JSONObject().put("unrelated",JSONObject().put("x",1)))
            .put("B",JSONObject().put("keep",true)).toString()
        val applied=scope.async(start=CoroutineStart.UNDISPATCHED) { store.execute(save) }
        queue.drain(); check(applied.await().isSuccess)
        val all=JSONObject(prefs.raw)
        check(all.getJSONObject("A").getJSONObject("unrelated").getInt("x")==1 && all.getJSONObject("B").getBoolean("keep"))
        queue.drain()
        val changed=ForYouEditSession(store.state.value)
        val stale=store.prepare(changed,ForYouInterests()).getOrThrow()
        prefs.raw=JSONObject(prefs.raw).also { it.getJSONObject("A").put(ForYouInterests.FIELD,JSONObject.NULL) }.toString()
        val staleResult=scope.async(start=CoroutineStart.UNDISPATCHED) { store.execute(stale) }; queue.drain()
        check(staleResult.await().isFailure && changed.isActive())
        // A known DTO edit overlays unknown value/rules members and emits exactly its collection.
        val id="00000000-0000-0000-0000-000000000002"
        val collection=SmartCollection(id,"Old",SmartCollectionRules(),true,1.0)
        val source=collection.toJson().put("futureValue",JSONObject().put("keep",true))
        source.getJSONObject("rules").put("futureRule",JSONObject().put("keep",true)).put("sort","future-sort")
        prefs.raw=JSONObject(prefs.raw).also { it.getJSONObject("A").put(collection.field,source) }.toString()
        store.reload(); queue.drain()
        val editing=ForYouEditSession(store.state.value)
        val edit=store.prepare(editing,collection.copy(name="New")).getOrThrow()
        val editResult=scope.async(start=CoroutineStart.UNDISPATCHED) { store.execute(edit) }; queue.drain()
        check(editResult.await().isSuccess)
        val saved=JSONObject(prefs.raw).getJSONObject("A").getJSONObject(collection.field)
        check(saved.getJSONObject("futureValue").getBoolean("keep") && saved.getJSONObject("rules").getJSONObject("futureRule").getBoolean("keep"))
        check(saved.getJSONObject("rules").getString("sort")=="future-sort")
        queue.drain()
        val deleting=ForYouEditSession(store.state.value)
        val frozenDelete=store.prepareDelete(deleting,collection).getOrThrow()
        // Confirmed delete is the same immutable intent even after a distinct collection appears.
        prefs.raw=JSONObject(prefs.raw).also { it.getJSONObject("A").put("future",JSONObject().put("keep",true)) }.toString()
        val deleteResult=scope.async(start=CoroutineStart.UNDISPATCHED) { store.execute(frozenDelete) }; queue.drain()
        check(deleteResult.await().isSuccess)
        check(JSONObject(prefs.raw).getJSONObject("A").isNull(collection.field) && JSONObject(prefs.raw).getJSONObject("A").has("future"))
        val oldCompletion=ForYouEditSession(store.state.value); var oldFinishes=0; var successorFinishes=0
        oldCompletion.close(); val successor=ForYouEditSession(store.state.value)
        oldCompletion.finishIfActive { oldFinishes++; successorFinishes++ }
        check(oldFinishes==0 && successorFinishes==0 && successor.isActive())
        println("PASS actual_store_prepare_original_local_signin_profile_ABA_unrelated_merge_stale_draft_and_completion_fence")
    } finally { scope.cancel() }
}
private suspend fun storeNativeInvalidationAndOpeningReplacement() {
    val queue=QueueDispatcher(); val nativeQueue=QueueDispatcher()
    val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
    try {
        val accounts=NativeAccountCoordinator(); val original=accounts.session().apply { seed() }
        val access=NativeForYouAccess(accounts,nativeQueue)
        val store=ForYouStore(Prefs(),{"A"},{true},{},scope,Dispatchers.Unconfined,queue)
        store.installNativeGateway(access)
        queue.drain(); check(store.state.value.ready)
        val opening=ForYouEditSession(store.state.value)
        val intent=store.prepare(opening,ForYouInterests(genres=listOf("drama"))).getOrThrow()
        val call=scope.async(start=CoroutineStart.UNDISPATCHED) { store.execute(intent) }
        store.invalidateNativeAuthority() // final native predicate sees the retired Store epoch
        check(!store.state.value.ready)
        store.reload(); queue.drain()
        val successorState=store.state.value; check(successorState.ready)
        nativeQueue.drain(); check(call.await().isFailure && original.commits==0)
        check(store.state.value === successorState) // old completion cannot clear/reload a successor view
        val old=ForYouEditSession(store.state.value)
        old.close(); val successor=ForYouEditSession(store.state.value)
        check(store.prepare(old,ForYouInterests()).isFailure && successor.isActive())
        println("PASS actual_store_to_native_queued_invalidation_prelaunch_replacement_old_completion_fence")
    } finally { scope.cancel() }
}
private fun missingAndDuplicatePeople() = JSONArray()
    .put(JSONObject().put("name","future-one").put("future","a"))
    .put(JSONObject().put("name","future-two").put("future","b"))
    .put(JSONObject().put("id",7).put("name","duplicate-one").put("future","c"))
    .put(JSONObject().put("id",7).put("name","duplicate-two").put("future","d"))
    .put(JSONObject().put("id",8).put("name","recognized").put("future",JSONObject().put("keep",true)))

private suspend fun actualStoreUnknownPeopleConservation() {
    val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
    try {
        val prefs=Prefs();val manager=VortXSyncManager()
        val interests=ForYouInterests(genres=listOf("drama")).toJson().put("people",missingAndDuplicatePeople())
        val collection=SmartCollection("00000000-0000-0000-0000-000000000003","Before",SmartCollectionRules(),true,1.0)
        val rawCollection=collection.toJson().also { it.getJSONObject("rules").put("people",missingAndDuplicatePeople()) }
        prefs.raw=JSONObject().put("A",JSONObject().put(ForYouInterests.FIELD,interests).put(collection.field,rawCollection)).toString()
        val store=ForYouStore(prefs,{"A"},{false},{},scope,Dispatchers.Unconfined,Dispatchers.Unconfined,
            captureLocalAuthority={manager.captureLocalLibraryMutationAuthority()})
        check(store.state.value.ready)
        val originalPeople=forYouCanonical(missingAndDuplicatePeople())
        val interestEdit=store.prepare(ForYouEditSession(store.state.value),checkNotNull(store.state.value.interests).copy(genres=listOf("scifi"))).getOrThrow()
        check(forYouCanonical(JSONObject(checkNotNull(interestEdit.encoded)).getJSONArray("people"))==originalPeople)
        check(store.execute(interestEdit).isSuccess)
        check(forYouCanonical(JSONObject(prefs.raw).getJSONObject("A").getJSONObject(ForYouInterests.FIELD).getJSONArray("people"))==originalPeople)
        val currentCollection=store.state.value.collections.single()
        val collectionEdit=store.prepare(ForYouEditSession(store.state.value),currentCollection.copy(name="After",home=false)).getOrThrow()
        check(forYouCanonical(JSONObject(checkNotNull(collectionEdit.encoded)).getJSONObject("rules").getJSONArray("people"))==originalPeople)
        check(store.execute(collectionEdit).isSuccess)
        check(forYouCanonical(JSONObject(prefs.raw).getJSONObject("A").getJSONObject(collection.field).getJSONObject("rules").getJSONArray("people"))==originalPeople)
        val prior=checkNotNull(store.state.value.interests)
        val changedList=prior.people.filterNot { it.id==8 }+ForYouPerson(9,"new")
        val changed=store.prepare(ForYouEditSession(store.state.value),prior.copy(people=changedList)).getOrThrow()
        check(store.execute(changed).isSuccess)
        val saved=JSONObject(prefs.raw).getJSONObject("A").getJSONObject(ForYouInterests.FIELD).getJSONArray("people")
        check(saved.length()==5)
        val unknown=missingAndDuplicatePeople()
        repeat(4) { index -> check(forYouJsonEqual(saved.get(index),unknown.get(index))) }
        check(saved.getJSONObject(4).getInt("id")==9)
        println("PASS actual_store_unchanged_people_exact_unknown_missing_ids_duplicates_unrelated_interest_collection_and_deliberate_list_change")
    } finally {scope.cancel()}
}

private suspend fun actualSameIoLocalCancellation() {
    val io=Dispatchers.Unconfined
    val scope=CoroutineScope(SupervisorJob()+io)
    val operationJob=Job()
    try {
        val prefs=Prefs();val manager=VortXSyncManager();var profileReads=0
        val store=ForYouStore(prefs,{profileReads++;"A"},{false},{},scope,io,io,
            captureLocalAuthority={manager.captureLocalLibraryMutationAuthority()})
        check(store.state.value.ready)
        val intent=store.prepare(ForYouEditSession(store.state.value),ForYouInterests(genres=listOf("drama"))).getOrThrow()
        val before=prefs.raw;val beforeCommits=prefs.commits;val beforeProfileReads=profileReads
        var propagated=false
        prefs.beforeRead={prefs.beforeRead=null;operationJob.cancel(CancellationException("cancel before local durability"))}
        val operation=CoroutineScope(operationJob+io).async(start=CoroutineStart.UNDISPATCHED) {
            try { store.execute(intent);error("Cancellation must escape actual same-IO execute") }
            catch(cancelled:CancellationException) {propagated=true;throw cancelled}
        }
        runCatching {operation.await()}
        check(propagated && prefs.raw==before && prefs.commits==beforeCommits)
        check(profileReads==beforeProfileReads) {"Cancelled local completion scheduled reload"}
        println("PASS actual_store_same_IO_local_cancellation_propagates_preserves_prefs_and_schedules_no_reload")
    } finally {operationJob.cancel();scope.cancel()}
}

private suspend fun actualStoreAndHomeConflation() {
    val scope=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
    val queue=QueueDispatcher()
    try {
        val accounts=NativeAccountCoordinator();val session=accounts.session().apply {seed()}
        val store=ForYouStore(Prefs(),{"A"},{true},{},scope,Dispatchers.Unconfined,queue)
        store.installNativeGateway(NativeForYouAccess(accounts,queue));queue.drain();check(store.state.value.ready)
        var stateCount=0;var homeCount=0
        val home=MutableStateFlow(forYouOpeningUi(store.state.value,true,false))
        val stateJob=scope.launch {store.state.collect {value ->stateCount++;home.value=forYouOpeningUi(value,value.ready,false)}}
        val homeJob=scope.launch {home.collect {homeCount++}}
        val settled=store.state.value;val homeSettled=home.value;val settledStateCount=stateCount;val settledHomeCount=homeCount
        repeat(4) {session.updates.value+=1;accounts.changes.value+=1;store.reload();queue.drain()}
        check(store.state.value===settled && home.value===homeSettled)
        check(stateCount==settledStateCount && homeCount==settledHomeCount)
        val oldOpening=ForYouEditSession(settled)
        val oldIntent=store.prepare(oldOpening,ForYouInterests(genres=listOf("drama"))).getOrThrow()
        session.fields.getJSONObject(ForYouInterests.FIELD).getJSONObject("value").put("futureUnknown",true)
        store.reload();queue.drain()
        check(store.state.value!=settled && store.state.value.interests==settled.interests)
        check(oldOpening.state===settled) // existing drafts retain their exact original immutable origin
        check(stateCount==settledStateCount+1 && homeCount==settledHomeCount+1)
        val rawChanged=store.state.value
        val newAccount=SessionOwnerSnapshot.Account("account-A",2)
        accounts.authenticated=newAccount;accounts.auth.operations.generation++;accounts.auth.sessionState.ownerEpoch++
        accounts.mounted.set(NativeAccountCoordinator.Mounted(session,newAccount))
        store.reload();queue.drain();check(store.state.value.ready && store.state.value!=rawChanged)
        val result=scope.async(start=CoroutineStart.UNDISPATCHED) {store.execute(oldIntent)};queue.drain()
        check(result.await().isFailure && session.commits==0)
        val beforeMount=store.state.value
        accounts.mounted.set(NativeAccountCoordinator.Mounted(session,newAccount))
        store.reload();queue.drain();check(store.state.value.ready && store.state.value!=beforeMount)
        val beforeAuthOperation=store.state.value
        accounts.auth.operations.generation++
        store.reload();queue.drain();check(store.state.value.ready && store.state.value!=beforeAuthOperation)
        val beforeAuthSession=store.state.value
        accounts.auth.sessionState.value=Any();accounts.auth.sessionState.ownerEpoch++
        store.reload();queue.drain();check(store.state.value.ready && store.state.value!=beforeAuthSession)
        val beforeABA=store.state.value
        session.owner=session.owner.copy(profileID="B",revision=2);session.owner=session.owner.copy(profileID="A",revision=3)
        store.reload();queue.drain();check(store.state.value.ready && store.state.value!=beforeABA)
        check(store.prepare(ForYouEditSession(store.state.value),ForYouInterests()).isSuccess)
        stateJob.cancel();homeJob.cancel()
        // Signed-out identity changes also distinguish auth/operation ABA from equal reloads.
        val prefs=Prefs();val manager=VortXSyncManager()
        val local=ForYouStore(prefs,{"A"},{false},{},scope,Dispatchers.Unconfined,Dispatchers.Unconfined,
            captureLocalAuthority={manager.captureLocalLibraryMutationAuthority()})
        val original=local.state.value;repeat(3) {local.reload();check(local.state.value===original)}
        manager.operations.generation++;local.reload();check(local.state.value!=original)
        val beforeLocalEpoch=local.state.value;manager.sessionState.ownerEpoch++
        local.reload();check(local.state.value!=beforeLocalEpoch)
        println("PASS actual_stateflow_home_projection_unchanged_progress_metadata_conflation_raw_unknown_account_generation_profile_ABA_and_local_operation_scope")
    } finally {scope.cancel()}
}
fun main()=runBlocking {
    originalNativeSchedules();actualStoreSchedules();storeNativeInvalidationAndOpeningReplacement()
    actualStoreUnknownPeopleConservation();actualSameIoLocalCancellation();actualStoreAndHomeConflation()
}
