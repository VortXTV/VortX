package com.vortx.android.player.mpv.seam

import java.util.ArrayDeque
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class MpvReferenceSessionTest {
    private val payload = """{"version":1,"language":"eng","cues":[{"startMs":100,"endMs":200,"text":"a"}]}"""
    private class ManualExecutor(private val inline: Boolean = false) : AbstractExecutorService() {
        private val tasks = ArrayDeque<Runnable>()
        private var stopped = false
        override fun execute(command: Runnable) { check(!stopped); if (inline) command.run() else tasks.add(command) }
        fun runAll() { var count = 0; while (tasks.isNotEmpty()) { check(count++ < 32); tasks.removeFirst().run() } }
        override fun shutdown() { stopped = true }
        override fun shutdownNow(): MutableList<Runnable> = tasks.toMutableList().also { tasks.clear(); stopped = true }
        override fun isShutdown() = stopped
        override fun isTerminated() = stopped && tasks.isEmpty()
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = isTerminated
    }

    private class Fixture(inlineCleanup: Boolean = false) {
        val owner = AtomicBoolean(true)
        val gate = MpvNativeHandleGate(17L)
        val executor = ManualExecutor(inlineCleanup)
        val commands = mutableListOf<Pair<Long, MpvReferenceCommand>>()
        val aborts = mutableListOf<Long>()
        val revokes = mutableListOf<Pair<Long, Long>>()
        var destroyed = 0
        var forceDestroy = 0
        var revokeOK = true
        var onBegin: ((Long, MpvReferenceCommand) -> Int)? = null
        lateinit var transport: MpvReferenceTransport
        init {
            gate.bindOriginalOwner(owner)
            val native = object : MpvReferenceNative {
                override fun property(handle: Long, property: Int) =
                    if (property == 0) MpvReferenceTestNodes.node(MpvReferenceTestNodes.fields()) else null
                override fun begin(handle: Long, identifier: Long, command: MpvReferenceCommand): Int {
                    assertEquals(17L, handle)
                    commands.add(identifier to command)
                    return onBegin?.invoke(identifier, command) ?: 0
                }
                override fun abort(handle: Long, identifier: Long) { assertEquals(17L, handle); aborts.add(identifier) }
                override fun revoke(handle: Long, grant: Long): Boolean { revokes.add(handle to grant); return revokeOK }
            }
            transport = MpvReferenceTransport({ gate }, native, {
                forceDestroy++
                val destroy = gate.requestDestroy { destroyed++ }
                transport.retire()
                destroy?.invoke()
            }, executor)
        }
        fun open() = transport.open(22L)!!
        fun reply(node: MpvReferenceNode?, error: Int = 0, id: Long = commands.last().first) = transport.reply(id, error, node)
        fun ready(session: MpvReferenceSession): MpvReferenceRequest {
            val request = session.read {}!!
            reply(MpvReferenceTestNodes.read())
            return request
        }
    }

    @Test fun `cancel before enqueue returns is replayed and late grant is retired`() {
        val fixture = Fixture()
        val session = fixture.open()
        var result: MpvReferenceReply? = null
        fixture.onBegin = { _, _ -> session.close(); 0 }
        val request = session.read { result = it }!!
        assertFalse(request.isTerminal)
        assertEquals(listOf(fixture.commands.single().first), fixture.aborts)
        fixture.executor.runAll()
        assertTrue(fixture.revokes.isEmpty()) // no synthetic completion or guessed grant
        fixture.reply(MpvReferenceTestNodes.read())
        assertTrue(request.isTerminal)
        assertSame(MpvReferenceReply.Cancelled, result)
        fixture.executor.runAll()
        assertEquals(listOf(17L to 31L), fixture.revokes)
        assertEquals(0, fixture.forceDestroy)
    }

    @Test fun `reply before native enqueue returns remains owned until call exit`() {
        val fixture = Fixture()
        val session = fixture.open()
        fixture.onBegin = { id, _ -> fixture.reply(MpvReferenceTestNodes.read(), id = id); 0 }
        var count = 0
        val request = session.read { count++ }!!
        assertTrue(request.isTerminal)
        assertEquals(1, count)
        session.close()
        fixture.executor.runAll()
        assertEquals(listOf(17L to 31L), fixture.revokes)
    }

    @Test fun `completed old request cancellation cannot cancel successor prepare`() {
        val fixture = Fixture()
        val session = fixture.open()
        val read = fixture.ready(session)
        var prepared: MpvReferenceReply? = null
        val next = session.prepare(payload) { prepared = it }!!
        val nextID = fixture.commands.last().first
        read.cancel()
        assertTrue(fixture.aborts.isEmpty())
        assertFalse(next.isTerminal)
        fixture.reply(MpvReferenceTestNodes.node(mapOf("version" to 2L, "grant" to 31L, "ticket" to 91L)), id = nextID)
        assertEquals(MpvReferenceReply.Prepared(31L, 91L), prepared)
        assertEquals(9, fixture.commands.last().second.integers.size)
        session.close(); fixture.executor.runAll()
        assertEquals(listOf(17L to 31L), fixture.revokes)
    }

    @Test fun `owner retirement still permits exact original handle cleanup`() {
        val fixture = Fixture()
        val session = fixture.open()
        var result: MpvReferenceReply? = null
        val request = session.read { result = it }!!
        fixture.owner.set(false)
        assertEquals(-1L, fixture.gate.withHandle(-1L) { it })
        fixture.reply(MpvReferenceTestNodes.read())
        assertTrue(request.isTerminal)
        assertSame(MpvReferenceReply.Cancelled, result)
        fixture.executor.runAll()
        assertEquals(listOf(17L to 31L), fixture.revokes)
        assertNull(session.read {})
    }

    @Test fun `unknown successful READ tears context down only after other real reply drains`() {
        val fixture = Fixture()
        val first = fixture.open()
        val second = fixture.open()
        var ordinaryAtCallback = 0L
        var callbackCount = 0
        val firstRequest = first.read {
            ordinaryAtCallback = fixture.gate.withHandle(-1L) { it }
            callbackCount++
        }!!
        val firstID = fixture.commands.last().first
        val secondRequest = second.read {}!!
        val secondID = fixture.commands.last().first
        fixture.transport.failedDelivery(firstID)
        assertTrue(firstRequest.isTerminal)
        assertEquals(1, fixture.forceDestroy) // admission closes before the callback/executor runs
        assertEquals(1, callbackCount)
        assertEquals(-1L, ordinaryAtCallback)
        assertEquals(-1L, fixture.gate.withHandle(-1L) { it })
        fixture.executor.runAll()
        assertEquals(1, fixture.forceDestroy)
        assertEquals(0, fixture.destroyed)
        assertFalse(secondRequest.isTerminal)
        assertTrue(secondID in fixture.aborts)
        fixture.reply(null, error = -1, id = secondID)
        fixture.executor.runAll()
        assertTrue(secondRequest.isTerminal)
        assertEquals(1, fixture.destroyed)
        assertTrue(fixture.revokes.isEmpty())
    }

    @Test fun `fast cleanup callback observes closed admission before destroy returns`() {
        val fixture = Fixture(inlineCleanup = true)
        val session = fixture.open()
        var closedCallbacks = 0
        var ordinaryAtClose = 0L
        var result: MpvReferenceClose? = null
        session.whenClosed {
            ordinaryAtClose = fixture.gate.withHandle(-1L) { it }
            result = it
            closedCallbacks++
        }
        session.read {}
        fixture.transport.failedDelivery(fixture.commands.last().first)
        // Assertions are outside callbacks: production deliberately contains client exceptions.
        assertEquals(1, closedCallbacks)
        assertEquals(-1L, ordinaryAtClose)
        assertEquals(MpvReferenceClose.TEARDOWN_REQUESTED, result)
        assertEquals(1, fixture.forceDestroy)
        assertEquals(1, fixture.destroyed)
    }

    @Test fun `callback driven destroy cannot strand original terminal or grant`() {
        val fixture = Fixture()
        val session = fixture.open()
        val request = session.read {
            val destroy = fixture.gate.requestDestroy { fixture.destroyed++ }
            fixture.transport.retire()
            destroy?.invoke()
        }!!
        fixture.reply(MpvReferenceTestNodes.read())
        assertTrue(request.isTerminal)
        assertEquals(0, fixture.destroyed)
        fixture.executor.runAll()
        assertEquals(1, fixture.destroyed)
        assertEquals(listOf(17L to 31L), fixture.revokes)
    }

    @Test fun `duplicate and unknown replies cannot consume a new request`() {
        val fixture = Fixture()
        val session = fixture.open()
        var count = 0
        session.read { count++ }
        val id = fixture.commands.single().first
        fixture.reply(MpvReferenceTestNodes.read(), id = id)
        fixture.reply(MpvReferenceTestNodes.read(), id = id)
        fixture.reply(MpvReferenceTestNodes.read(), id = id + 500)
        assertEquals(1, count)
        session.close(); fixture.executor.runAll()
        assertEquals(listOf(17L to 31L), fixture.revokes)
    }

    @Test fun `native enqueue rejection remains an error not user cancellation`() {
        val fixture = Fixture()
        val session = fixture.open()
        fixture.onBegin = { _, _ -> -4 }
        var reply: MpvReferenceReply? = null
        val request = session.read { reply = it }!!
        assertTrue(request.isTerminal)
        assertEquals(MpvReferenceReply.Rejected(-4), reply)
        fixture.executor.runAll()
        assertTrue(fixture.revokes.isEmpty())
        assertEquals(0, fixture.forceDestroy)
    }

    @Test fun `unconfirmed revoke closes ordinary admission and requests teardown once`() {
        val fixture = Fixture()
        val session = fixture.open()
        fixture.ready(session)
        fixture.revokeOK = false
        var closed: MpvReferenceClose? = null
        session.whenClosed { closed = it }
        session.close(); session.close(); fixture.executor.runAll()
        assertEquals(MpvReferenceClose.TEARDOWN_REQUESTED, closed)
        assertEquals(1, fixture.forceDestroy)
        assertEquals(1, fixture.destroyed)
        assertEquals(-1L, fixture.gate.withHandle(-1L) { it })
        assertEquals(listOf(17L to 31L), fixture.revokes)
    }

    @Test fun `throwing client callback cannot leak its completed READ grant`() {
        val fixture = Fixture()
        val session = fixture.open()
        val request = session.read { error("controlled callback failure") }!!
        fixture.reply(MpvReferenceTestNodes.read())
        assertTrue(request.isTerminal)
        fixture.executor.runAll()
        assertEquals(listOf(17L to 31L), fixture.revokes)
    }
}
