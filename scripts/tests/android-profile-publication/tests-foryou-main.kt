package com.vortx.android.engine
import com.vortx.android.foryou.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

fun runForYouReloadBoundaryCases() = runBlocking {
    val uiExecutor=java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it,"foryou-ui").apply { isDaemon=true } }
    val ioExecutor=java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it,"foryou-io").apply { isDaemon=true } }
    val ui=uiExecutor.asCoroutineDispatcher();val io=ioExecutor.asCoroutineDispatcher()
    val scope=CoroutineScope(SupervisorJob()+kotlinx.coroutines.Dispatchers.Default)
    try {
        var active="A";var owner="A";var epoch=1L;var listener:()->Unit={}
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val captures=AtomicInteger()
        val gateway=object:ForYouNativeGateway {
            override val changes=emptyFlow<Unit>()
            override fun capture():Result<ForYouNativeGateway.Snapshot> {
                check(Thread.currentThread().name=="foryou-io")
                val selected=owner;val version=epoch
                if(captures.incrementAndGet()==1) {
                    entered.countDown();check(release.await(5,TimeUnit.SECONDS))
                }
                return Result.success(ForYouNativeGateway.Snapshot(object:ForYouNativeGateway.Owner { override val profileId=selected; override val scopeIdentity=listOf(selected,version) },
                    JSONObject().put(ForYouInterests.FIELD,JSONObject().put("value",ForYouInterests(genres=listOf(selected)).toJson()))) { action ->
                    if(selected==owner && version==epoch) { action();true } else false
                })
            }
            override suspend fun write(owner:ForYouNativeGateway.Owner,field:String,observed:ForYouObservedField,value:Any,isCurrent:()->Boolean)=Result.success(Unit)
        }
        val store=ForYouStore(object:android.content.SharedPreferences {},
            activeProfileId={check(Thread.currentThread().name=="foryou-ui");active},signedIn={true},
            registerProfileSwitch={listener=it},scope=scope,mainDispatcher=ui,ioDispatcher=io)
        store.installNativeGateway(gateway)
        withContext(kotlinx.coroutines.Dispatchers.IO) { check(entered.await(5,TimeUnit.SECONDS)) }
        withContext(ui) {
            active="B";owner="B";epoch++
            listener()
            check(!store.state.value.ready && store.state.value.interests==null)
            repeat(5) { store.reload() }
        }
        check(captures.get()==1) { "Synchronous switch hook performed a native capture" }
        release.countDown()
        withTimeout(5000) { while(!store.state.value.ready) delay(5) }
        check(store.state.value.profileId=="B" && store.state.value.interests?.genres==listOf("B"))
        check(captures.get()==2) { "Superseded native reloads were not coalesced" }
        store.invalidateNativeAuthority()
        check(!store.state.value.ready && store.state.value.interests==null)
        println("PASS actual_foryou_switch_clears_immediately_capture_is_io_cancelled_queue_skips_and_stale_owner_cannot_publish")
    } finally {
        scope.cancel();ui.close();io.close();uiExecutor.shutdownNow();ioExecutor.shutdownNow()
    }
}
