package com.vortx.android.library

import kotlin.random.Random
import org.json.JSONArray
import org.json.JSONObject

/** Printed fixtures are fake metadata only; Node independently verifies the exact source writer. */
internal object NativeWatchlistCanonicalFixture {
    @JvmStatic fun main(args: Array<String>) {
        val profile = "00000000-0000-0000-0000-00000000A11C"
        val numbers = mutableListOf(0.0, -0.0, 123.5, Double.MIN_VALUE, 1e-7, 1e-6,
            Math.nextDown(1e-6), Math.nextUp(1e-6), Math.nextDown(1.0), Math.nextUp(1.0),
            1_767_225_600.1235, 9_007_199_254_740_991.0)
        val random = Random(0x05FA113)
        while (numbers.size < 512) {
            val candidate = Double.fromBits(random.nextLong().ushr(1))
            if (candidate.isFinite() && candidate >= 0 && candidate <= 9_007_199_254_740_991.0) numbers += candidate
        }
        val rows = JSONArray()
        numbers.forEachIndexed { index, number ->
            val name = if (number == 123.5) "🍿 / Revised" else listOf(
                "🍿 / Revised", "Quotes \" and \\ and \n \u0000", "Unicode \u2028 \u2029 🌕", "</script> /",
            )[index % 4]
            val poster = if (index % 3 == 0) "https://fixture.invalid/poster/$index.jpg" else null
            val item = WatchlistEntry("tt123", "movie", name, poster, number)
            rows.put(JSONObject().put("profileId", profile).put("field", NativeWatchlistCodec.field(item.id, item.type))
                .put("value", NativeWatchlistCodec.value(item)).put("seconds", NativeWatchlistCodec.canonicalSeconds(number))
                .put("canonical", NativeWatchlistCodec.baselineCanonicalJSON(profile, item))
                .put("actor", NativeWatchlistCodec.baselineActor(profile, item)))
        }
        println(rows.toString())
    }
}
