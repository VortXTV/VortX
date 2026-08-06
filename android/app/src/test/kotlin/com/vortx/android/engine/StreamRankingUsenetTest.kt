package com.vortx.android.engine

import com.vortx.android.model.StreamSource
import com.vortx.android.sources.SourcePrefsSnapshot
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamRankingUsenetTest {

    @Test
    fun structuralUsenetSourceRanksAboveEquivalentRawTorrentWithoutLabelHints() {
        val usenet = StreamSource(
            id = "opaque-usenet-handle",
            addon = "Test",
            title = "2160p WEB-DL",
            nzbUrl = "https://example.invalid/fetch/opaque",
        )
        val torrent = StreamSource(
            id = "opaque-torrent-handle",
            addon = "Test",
            title = "2160p WEB-DL",
            isTorrent = true,
            infoHash = "abcdef0123456789",
        )

        val usenetScore = StreamRanking.score(usenet, SourcePrefsSnapshot.DEFAULT)
        val torrentScore = StreamRanking.score(torrent, SourcePrefsSnapshot.DEFAULT)

        assertTrue(
            "Structural Usenet must receive the Usenet tier even when its labels contain no NZB words",
            usenetScore > torrentScore,
        )
    }
}
