package com.vortx.android.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class EngineActionsSearchTest {
    @Test
    fun `search unload targets only the search field`() {
        val envelope = JSONObject(EngineActions.searchUnload())
        val action = envelope.getJSONObject("action")

        assertEquals("search", envelope.getString("field"))
        assertEquals("Unload", action.getString("action"))
        assertFalse(action.has("args"))
    }
}
