package com.vortx.android.engine

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class EngineActionsAddonFlagsTest {
    private fun descriptor(action: String) = JSONObject(action).getJSONObject("action").getJSONObject("args").getJSONObject("args")
    @Test fun `new user install never promotes flags supplied by an untrusted manifest`() {
        val manifest = JSONObject().put("id", "fixture").put("name", "Fixture")
            .put("flags", JSONObject().put("official", true).put("protected", true))
        val flags = descriptor(EngineActions.installAddon("https://fixture.invalid/manifest.json", manifest)).getJSONObject("flags")
        assertFalse(flags.getBoolean("official")); assertFalse(flags.getBoolean("protected"))
    }
    @Test fun `owned update preserves detached trusted descriptor flags`() {
        val flags = JSONObject().put("official", true).put("protected", true)
        val action = EngineActions.installAddon("https://fixture.invalid/manifest.json", JSONObject().put("id", "fixture"), flags)
        flags.put("protected", false)
        assertTrue(descriptor(action).getJSONObject("flags").getBoolean("official"))
        assertTrue(descriptor(action).getJSONObject("flags").getBoolean("protected"))
    }
}
