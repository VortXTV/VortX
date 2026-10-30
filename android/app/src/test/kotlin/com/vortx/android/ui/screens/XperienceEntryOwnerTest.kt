package com.vortx.android.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test

/** SOURCE ONLY / UNRUN. Uses the real UI entry owner; no controller/native/cloud proof. */
class XperienceEntryOwnerTest {
    private class Probe : ViewModel() {
        var clears = 0
        override fun onCleared() { clears++ }
    }

    @Test fun `one current entry reuses its store and replacement clears original once`() {
        val holder = XperienceEntryOwner()
        val original = holder.owner("original")
        val probe = Probe().also { original.viewModelStore.put("probe", it) }
        assertSame(original, holder.owner("original"))
        assertEquals(0, probe.clears)
        val replacement = holder.owner("replacement")
        assertNotSame(original, replacement)
        assertEquals(1, probe.clears)
        holder.release("original")
        assertEquals(1, probe.clears)
        holder.release("replacement")
    }

    @Test fun `late original release never clears successor store`() {
        val holder = XperienceEntryOwner()
        holder.owner("a")
        val successor = holder.owner("b")
        val probe = Probe().also { successor.viewModelStore.put("probe", it) }
        holder.release("a")
        assertSame(successor, holder.owner("b"))
        assertEquals(0, probe.clears)
        holder.release("b")
        assertEquals(1, probe.clears)
        assertNotSame(successor, holder.owner("b"))
        holder.release("b")
    }

    @Test fun `actual parent store clear clears owned controller store once`() {
        val parent = ViewModelStore()
        val holder = XperienceEntryOwner().also { parent.put("entry-holder", it) }
        val child = holder.owner("entry")
        val probe = Probe().also { child.viewModelStore.put("probe", it) }
        parent.clear()
        assertEquals(1, probe.clears)
        holder.release("entry")
        assertEquals(1, probe.clears)
    }
}
