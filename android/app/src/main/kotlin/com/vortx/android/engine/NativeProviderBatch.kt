package com.vortx.android.engine

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

internal const val NATIVE_PROVIDER_BUDGET_MS = 20_000L
internal const val NATIVE_PROVIDER_BODY_BYTES = 8_388_608L
internal const val NATIVE_RESOURCE_RESULT_BYTES = 33_554_432L

/** A series progress write must carry an actual video target, never a guessed title-level fallback. */
internal fun nativePlaybackIdentityCanRecord(context: com.vortx.android.model.PlaybackContext): Boolean =
    context.contentId.isNotBlank() && context.videoId.isNotBlank() && context.type in setOf("movie", "series") &&
        (context.type != "series" || context.videoId != context.contentId)

internal data class NativeProviderLeg(val request: VortxResourceRequest, val addon: VortxResourceAddon)
internal data class NativeProviderUpdate(val pages: List<VortxResourceSnapshot>, val settled: Int, val total: Int,
    val settledByResource: Map<VortxResourceRequest.Resource, Int> = emptyMap()) {
    val pending: Boolean get() = settled < total
    fun resourceSettled(resource: VortxResourceRequest.Resource, requested: Int): Boolean =
        requested == 0 || (settledByResource[resource] ?: 0) >= requested
}

/** A resource owns its aggregate allowance; one large peer never reduces every provider's body limit. */
internal class NativeProviderResultBudget(private val limit: Long = NATIVE_RESOURCE_RESULT_BYTES) {
    private val used = mutableMapOf<VortxResourceRequest.Resource, Long>()
    fun admit(page: VortxResourceSnapshot): VortxResourceSnapshot = page.copy(groups = page.groups.map { group ->
        if (group.status != "ready") group else {
            val bytes = requireNotNull(group.contentJson).toByteArray(Charsets.UTF_8).size.toLong()
            val prior = used[page.request.resource] ?: 0L
            if (bytes > NATIVE_PROVIDER_BODY_BYTES || bytes > limit - prior) {
                group.copy(status = "error", contentJson = null, errorCode = "response_budget_exceeded")
            } else {
                used[page.request.resource] = prior + bytes
                group
            }
        }
    })
}

/** Six independent host calls at most: four streams and two metadata. Queue time is NOT request time.
 * Settlements are serialized and receipts remain in registry order. Only admitted content is retained.
 */
internal suspend fun collectNativeProviderBatch(
    legs: List<NativeProviderLeg>,
    load: suspend (NativeProviderLeg) -> VortxResourceSnapshot,
    onUpdate: suspend (NativeProviderUpdate) -> Unit,
) = coroutineScope {
    if (legs.isEmpty()) { onUpdate(NativeProviderUpdate(emptyList(), 0, 0)); return@coroutineScope }
    val streams = Semaphore(4)
    val metadata = Semaphore(2)
    val settled = Channel<Pair<Int, Result<VortxResourceSnapshot>>>(capacity = 2)
    val pages = MutableList<VortxResourceSnapshot?>(legs.size) { null }
    val budget = NativeProviderResultBudget()
    val settledByResource = mutableMapOf<VortxResourceRequest.Resource, Int>()
    val jobs = legs.mapIndexed { index, leg -> launch {
        val permits = if (leg.request.resource == VortxResourceRequest.Resource.STREAM) streams else metadata
        val result = try { Result.success(permits.withPermit { load(leg) }) }
        catch (error: CancellationException) {
            // Parent/collector retirement cancels this child too, but must not replace a Flow.first
            // abort with a new parent cancellation. An independently cancelled peer settles as failure.
            currentCoroutineContext().ensureActive()
            Result.failure(error)
        }
        catch (error: Exception) { Result.failure(error) }
        catch (error: LinkageError) { Result.failure(error) }
        settled.send(index to result)
    } }
    try {
        repeat(legs.size) { completed ->
            val (index, result) = settled.receive()
            result.getOrNull()?.let { page -> pages[index] = budget.admit(page) }
            val resource = legs[index].request.resource
            settledByResource[resource] = (settledByResource[resource] ?: 0) + 1
            onUpdate(NativeProviderUpdate(pages.filterNotNull(), completed + 1, legs.size, settledByResource.toMap()))
        }
    } finally { jobs.forEach { it.cancel() }; settled.close() }
}
