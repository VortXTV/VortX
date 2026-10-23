package com.vortx.android.imports

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Public list GETs use the same address-pinned transport as add-on manifests. Every redirect
 * receives URL admission again; custom headers never leave their original origin. */
internal object ImportHttp {
    private val fetcher by lazy { ImportTextFetcher(ListImport.BROWSER_UA) }

    suspend fun fetchText(
        urlString: String,
        headers: Map<String, String> = emptyMap(),
        followRedirects: Boolean = true,
    ): String? = withContext(Dispatchers.IO) {
        val context = currentCoroutineContext()
        fetcher.fetch(urlString, headers, followRedirects) { context.ensureActive() }
    }
}
