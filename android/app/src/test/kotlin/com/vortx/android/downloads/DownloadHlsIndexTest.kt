package com.vortx.android.downloads

import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.DownloadState
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class DownloadHlsIndexTest {
    private val id = "11111111-2222-4333-8444-555555555555"
    private fun record() = DownloadRecord(id = id, contentId = "show", videoId = "show:1:2", type = "series",
        name = "Show", season = 1, episode = 2, remoteURL = "https://example.test/vod.m3u8",
        localFilename = "$id.hls", isHlsOffline = true, requiresSourceAuthority = true,
        requiresSourceLease = true, state = DownloadState.COMPLETED, bytesTotal = 1234, bytesDone = 1234)

    @Test fun `HLS format and source authority round trip through actual index codec`() {
        val original = record()
        val encoded = DownloadStore.recordToJson(original)
        assertEquals(original, DownloadStore.decodeIndexRecords(JSONArray().put(encoded).toString()).single())
    }

    @Test fun `HLS flag must match canonical package artifact name before hydration can authorize cleanup`() {
        val mismatched = DownloadStore.recordToJson(record().copy(isHlsOffline = false))
        assertThrows(IllegalArgumentException::class.java) {
            DownloadStore.decodeIndexRecords(JSONArray().put(mismatched).toString())
        }
        val traversal = DownloadStore.recordToJson(record().copy(localFilename = "../$id.hls"))
        assertThrows(IllegalArgumentException::class.java) {
            DownloadStore.decodeIndexRecords(JSONArray().put(traversal).toString())
        }
    }

    @Test fun `old progressive records decode without invented source authority`() {
        val old = DownloadStore.recordToJson(record().copy(localFilename = "$id.mp4", isHlsOffline = false))
        old.remove("isHlsOffline")
        old.remove("requiresSourceAuthority")
        old.remove("requiresSourceLease")
        val decoded = DownloadStore.decodeIndexRecords(JSONArray().put(old).toString()).single()
        assertFalse(decoded.isHlsOffline)
        assertFalse(decoded.requiresSourceAuthority)
        assertFalse(decoded.requiresSourceLease)
    }
}
