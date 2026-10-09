package com.vortx.android.sync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AccountTransferControllerTest {
    private class Session(var probeResult: AccountTransferSession.Probe = AccountTransferSession.Probe.HAS_DATA) : AccountTransferSession {
        val calls = mutableListOf<String>()
        var current = true
        var accepted = true
        var localData = true
        var pending = false
        override fun canKeepDevice() = localData
        override fun hasPendingChanges() = pending
        var probeWait: CompletableDeferred<Unit>? = null
        var actionWait: CompletableDeferred<Unit>? = null
        override fun isCurrent() = current
        override suspend fun probe(): AccountTransferSession.Probe { calls += "probe"; probeWait?.await(); return probeResult }
        private suspend fun action(name: String): Boolean { calls += name; actionWait?.await(); return accepted && current }
        override suspend fun seed() = action("seed")
        override suspend fun keepDevice() = action("device")
        override suspend fun restore() = action("restore")
        override suspend fun merge() = action("merge")
        override fun resumeSync(): Boolean { calls += "realtime"; return true }
        override fun abandon() { calls += "abandon" }
    }

    @Test fun `both existing-account directions wait for choice without a write or realtime start`() = runTest {
        for (direction in AccountTransferDirection.entries) {
            val session = Session(); val controller = AccountTransferController { session }
            controller.prepare(direction); controller.authenticated()
            assertEquals(AccountTransferStage.CHOOSE, controller.state.value.stage)
            assertEquals(listOf("probe"), session.calls)
        }
    }

    @Test fun `unmounted new account never offers or dispatches keep device and cannot seed an empty backup`() = runTest {
        for (empty in listOf(false, true)) {
            val session = Session(if (empty) AccountTransferSession.Probe.EMPTY else AccountTransferSession.Probe.HAS_DATA).apply { localData = false }
            val controller = AccountTransferController { session }
            controller.prepare(AccountTransferDirection.BACKUP); controller.authenticated()
            controller.choose(AccountTransferChoice.KEEP_DEVICE)
            assertEquals(listOf("probe"), session.calls)
            assertEquals(if (empty) AccountTransferStage.FAILED else AccountTransferStage.CHOOSE, controller.state.value.stage)
            if (!empty) {
                assertFalse(controller.state.value.canKeepDevice)
                controller.choose(AccountTransferChoice.USE_ACCOUNT)
                assertEquals(listOf("probe", "restore", "realtime"), session.calls)
            }
        }
    }

    @Test fun `unsynced intent keeps restore at explicit choice and permits an explicit merge`() = runTest {
        val session = Session().apply { pending = true }; val controller = AccountTransferController { session }
        controller.prepare(AccountTransferDirection.RESTORE); controller.authenticated()
        controller.choose(AccountTransferChoice.USE_ACCOUNT)
        assertEquals(AccountTransferStage.CHOOSE, controller.state.value.stage); assertEquals(listOf("probe"), session.calls)
        assertNotNull(controller.state.value.message)
        controller.choose(AccountTransferChoice.MERGE)
        assertEquals(listOf("probe", "merge", "realtime"), session.calls)
    }

    @Test fun `each conflict choice dispatches its actual direction exactly once`() = runTest {
        for ((choice, call) in listOf(AccountTransferChoice.KEEP_DEVICE to "device",
            AccountTransferChoice.USE_ACCOUNT to "restore", AccountTransferChoice.MERGE to "merge")) {
            val session = Session(); val controller = AccountTransferController { session }
            controller.prepare(AccountTransferDirection.BACKUP); controller.authenticated()
            controller.choose(choice); controller.choose(choice); controller.authenticated()
            assertEquals(listOf("probe", call, "realtime"), session.calls)
            assertEquals(AccountTransferStage.COMPLETE, controller.state.value.stage)
        }
    }

    @Test fun `empty backup seeds but empty restore never writes`() = runTest {
        for (direction in AccountTransferDirection.entries) {
            val session = Session(AccountTransferSession.Probe.EMPTY); val controller = AccountTransferController { session }
            controller.prepare(direction); controller.authenticated()
            assertEquals(if (direction == AccountTransferDirection.BACKUP) listOf("probe", "seed", "realtime") else listOf("probe"), session.calls)
            assertEquals(if (direction == AccountTransferDirection.BACKUP) AccountTransferStage.COMPLETE else AccountTransferStage.FAILED, controller.state.value.stage)
        }
    }

    @Test fun `unreachable or unavailable owner never masquerades as an empty account`() = runTest {
        val missing = AccountTransferController { null }
        missing.prepare(AccountTransferDirection.BACKUP); missing.authenticated()
        assertEquals(AccountTransferStage.FAILED, missing.state.value.stage)
        val session = Session(AccountTransferSession.Probe.UNAVAILABLE); val controller = AccountTransferController { session }
        controller.prepare(AccountTransferDirection.BACKUP); controller.authenticated()
        assertEquals(listOf("probe"), session.calls)
        assertEquals(AccountTransferStage.FAILED, controller.state.value.stage)
    }

    @Test fun `session or profile retired while probing cannot expose a choice or seed`() = runTest {
        val session = Session(AccountTransferSession.Probe.EMPTY).apply { probeWait = CompletableDeferred() }
        val controller = AccountTransferController { session }
        controller.prepare(AccountTransferDirection.BACKUP)
        val task = launch { controller.authenticated() }; runCurrent()
        session.current = false; session.probeWait!!.complete(Unit); task.join()
        assertEquals(listOf("probe"), session.calls)
        assertEquals(AccountTransferStage.FAILED, controller.state.value.stage)
    }

    @Test fun `a conflict choice never recaptures the replacement owner`() = runTest {
        val old = Session(); val replacement = Session(); var current = old
        val controller = AccountTransferController { current }
        controller.prepare(AccountTransferDirection.BACKUP); controller.authenticated()
        old.current = false; current = replacement
        controller.choose(AccountTransferChoice.KEEP_DEVICE)
        assertEquals(listOf("probe"), old.calls); assertTrue(replacement.calls.isEmpty())
        assertEquals(AccountTransferStage.FAILED, controller.state.value.stage)
    }

    @Test fun `late QR approval from cancelled request cannot authorize a later restore`() = runTest {
        val session = Session(); val controller = AccountTransferController { session }
        controller.prepare(AccountTransferDirection.BACKUP); val old = controller.requestToken
        controller.cancel(); controller.prepare(AccountTransferDirection.RESTORE)
        controller.authenticated(old)
        assertEquals(AccountTransferStage.SIGN_IN, controller.state.value.stage); assertTrue(session.calls.isEmpty())
        controller.authenticated(controller.requestToken)
        assertEquals(listOf("probe"), session.calls)
    }

    @Test fun `duplicate approval and choice while suspended do not repeat actions`() = runTest {
        val session = Session().apply { probeWait = CompletableDeferred(); actionWait = CompletableDeferred() }
        val controller = AccountTransferController { session }
        controller.prepare(AccountTransferDirection.BACKUP)
        val approval = launch { controller.authenticated() }; runCurrent()
        controller.authenticated(); session.probeWait!!.complete(Unit); approval.join()
        val choice = launch { controller.choose(AccountTransferChoice.KEEP_DEVICE) }; runCurrent()
        controller.choose(AccountTransferChoice.USE_ACCOUNT)
        session.actionWait!!.complete(Unit); choice.join()
        assertEquals(listOf("probe", "device", "realtime"), session.calls)
    }

    @Test fun `failed or retired transfer never reports success or starts realtime`() = runTest {
        val session = Session().apply { actionWait = CompletableDeferred() }; val controller = AccountTransferController { session }
        controller.prepare(AccountTransferDirection.RESTORE); controller.authenticated()
        val task = launch { controller.choose(AccountTransferChoice.USE_ACCOUNT) }; runCurrent()
        session.current = false; session.actionWait!!.complete(Unit); task.join()
        assertEquals(listOf("probe", "restore"), session.calls)
        assertEquals(AccountTransferStage.FAILED, controller.state.value.stage)
    }

    @Test fun `cancelled in-flight probe cannot publish into a newly prepared flow`() = runTest {
        val session = Session(AccountTransferSession.Probe.EMPTY).apply { probeWait = CompletableDeferred() }
        val controller = AccountTransferController { session }
        controller.prepare(AccountTransferDirection.BACKUP)
        val task = launch { controller.authenticated() }; runCurrent()
        controller.cancel(); controller.prepare(AccountTransferDirection.RESTORE)
        session.probeWait!!.complete(Unit); task.join()
        assertEquals(listOf("probe", "abandon"), session.calls)
        assertEquals(AccountTransferState(AccountTransferDirection.RESTORE, AccountTransferStage.SIGN_IN), controller.state.value)
    }
}
