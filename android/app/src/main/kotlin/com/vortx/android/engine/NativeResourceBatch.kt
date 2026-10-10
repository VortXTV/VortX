package com.vortx.android.engine

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/** Independent resource legs settle in arrival order; snapshots always retain registry order. */
internal suspend fun <T : Any> collectNativeResourceBatch(
    count: Int,
    concurrency: Int = 4,
    load: suspend (Int) -> T,
    onUpdate: suspend (List<T>, Boolean) -> Unit,
) = coroutineScope {
    require(count >= 0 && concurrency > 0)
    if (count == 0) {
        onUpdate(emptyList(), false)
        return@coroutineScope
    }
    val permits = Semaphore(concurrency)
    val settled = Channel<Pair<Int, Result<T>>>(Channel.UNLIMITED)
    val results = MutableList<Result<T>?>(count) { null }
    val jobs = List(count) { index ->
        launch {
            val result = try { Result.success(permits.withPermit { load(index) }) }
            catch (error: CancellationException) {
                this@coroutineScope.cancel("Native resource batch cancelled", error)
                throw error
            }
            catch (error: Exception) { Result.failure(error) }
            catch (error: LinkageError) { Result.failure(error) }
            settled.send(index to result)
        }
    }
    try {
        repeat(count) { completed ->
            val (index, result) = settled.receive()
            results[index] = result
            val pages = results.mapNotNull { it?.getOrNull() }
            // A failed leg never replaces the already accepted successful legs with an error.
            if (completed == count - 1 && pages.isEmpty()) {
                throw requireNotNull(results.firstNotNullOfOrNull { it?.exceptionOrNull() })
            }
            onUpdate(pages, completed < count - 1)
        }
    } finally {
        jobs.forEach { it.cancel() }
        settled.close()
    }
}
