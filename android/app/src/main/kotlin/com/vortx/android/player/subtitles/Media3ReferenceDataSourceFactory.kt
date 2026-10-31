package com.vortx.android.player.subtitles

import android.net.Uri
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.IOException

/** Observe ONE original primary response; never alter playback IO, requests, callbacks or credentials. */
@UnstableApi
internal class Media3ReferenceDataSourceFactory(
    private val delegate: DataSource.Factory,
    private val capture: Media3EmbeddedReferenceCapture,
) : DataSource.Factory {
    override fun createDataSource(): DataSource {
        capture.dataSourceCreationStarted()
        val original = try {
            delegate.createDataSource()
        } catch (error: RuntimeException) {
            capture.fail()
            throw error
        }
        capture.dataSourceCreated(original)
        return Media3ReferenceDataSource(original, capture)
    }
}

@UnstableApi
internal class Media3ReferenceDataSource(
    private val delegate: DataSource,
    private val capture: Media3EmbeddedReferenceCapture,
) : DataSource {
    override fun addTransferListener(transferListener: TransferListener) = delegate.addTransferListener(transferListener)
    override fun getUri(): Uri? = delegate.uri
    override fun getResponseHeaders(): Map<String, List<String>> = delegate.responseHeaders

    override fun open(dataSpec: DataSpec): Long {
        // A URI pointing at a subrange cannot establish a complete original resource from byte zero.
        if (dataSpec.uriPositionOffset != 0L) capture.fail()
        val completeRequest = try { requestHasNoRange(dataSpec.httpRequestHeaders) } catch (_: Exception) { false }
        if (!completeRequest) capture.fail()
        capture.responseOpened(delegate, dataSpec.position, dataSpec.length)
        val result = try {
            delegate.open(dataSpec)
        } catch (error: IOException) {
            capture.fail()
            throw error
        } catch (error: RuntimeException) {
            capture.fail()
            throw error
        }
        // A position-zero request may still return only part of an entity. Never certify it.
        // Inspection failure belongs to OPTIONAL capture; the successful playback result survives.
        val completeResponse = try {
            responseHasNoContentRange(delegate.responseHeaders)
        } catch (_: Exception) {
            false
        }
        if (completeResponse) capture.responseOpenSucceeded(delegate) else capture.fail()
        return result
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int = try {
        delegate.read(buffer, offset, length)
    } catch (error: IOException) {
        capture.fail()
        throw error
    } catch (error: RuntimeException) {
        capture.fail()
        throw error
    }

    override fun close() {
        capture.responseClosed(delegate)
        try {
            delegate.close()
        } catch (error: IOException) {
            capture.fail()
            throw error
        } catch (error: RuntimeException) {
            capture.fail()
            throw error
        }
    }

    private fun requestHasNoRange(headers: Map<*, *>?): Boolean {
        if (headers == null || headers.size > MAX_HEADER_FIELDS) return false
        return headers.all { (name, value) ->
            name is String && name.length <= MAX_HEADER_NAME_CHARS && value is String &&
                !name.trim().equals("Range", ignoreCase = true)
        }
    }

    private fun responseHasNoContentRange(headers: Map<*, *>?): Boolean {
        if (headers == null || headers.size > MAX_HEADER_FIELDS) return false
        return headers.all { (name, values) ->
            name is String && name.length <= MAX_HEADER_NAME_CHARS && !name.trim().equals("Content-Range", ignoreCase = true) &&
                values is List<*> && values.size <= MAX_HEADER_VALUES && values.all { it is String }
        }
    }

    private companion object {
        const val MAX_HEADER_FIELDS = 256
        const val MAX_HEADER_VALUES = 64
        const val MAX_HEADER_NAME_CHARS = 256
    }
}
