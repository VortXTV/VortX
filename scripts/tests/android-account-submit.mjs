#!/usr/bin/env node
// Emits a disposable Kotlin harness containing exact production decisions. Does not compile/run.
// The runner supplies an exclusive output path beneath this repository's build folder.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
const input = process.argv[2];
const output = process.argv[3];
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
assert(input && output && resolve(input) === resolve(repo, 'android/app/src/main/kotlin/com/vortx/android/ui/viewmodel/VortXAccountViewModel.kt'), 'exact app source required');
assert(resolve(output).startsWith(resolve(repo, 'android/app/build') + sep), 'build output required');
const source = await readFile(input, 'utf8');
// Preserved method bytes from 72478298; no historical/shallow Git checkout dependency.
const unchanged = {
  signIn: '044157759a02c655f4b3e41795c7d983191a9b6f9d4128519c95db34c453c416',
  register: 'f409d11f1974925feb4e0911b8de41635add82d5462f827ae7788e99e051e7ab',
  recover: '032954e21e47867d0051b90a33979cb4610d01911b7f18c39c1bdd2239ba0765',
  onAuthed: 'cab39e26f49c34a2b7450b7798a68d8c9aaef8302a722f1e754a3c966299d329',
  onQrAuthed: '4073ce538c81b2138a2ab34d7a50e3aeb84e30047733d011faca72b335e113fa',
  finishPostAuth: 'ac38cb43d4225c966bf861510826c7b3503c6428cef84a9bca59d03a714360b9',
};
for (const [name, expected] of Object.entries(unchanged)) {
  const expression = new RegExp('    (?:private |internal )?(?:suspend )?fun ' + name + '\\([^]*?\\n    \\}');
  const actual = source.match(expression)?.[0];
  assert(actual && createHash('sha256').update(actual).digest('hex') === expected, `Out-of-scope ${name} body changed; review before updating the fixture`);
}
function method(name) {
  const match = source.match(new RegExp('    (?:private )?fun ' + name + '\\([^]*?\\n    \\}'));
  assert(match, `Missing production method ${name}`); return match[0];
}
const setters = ['onLoginChange', 'onUsernameChange', 'onPasswordChange', 'onTotpChange', 'onRecoveryInputChange'].map(name => {
  const match = source.match(new RegExp('    fun ' + name + '\\(value: String\\) \\{[^\\n]+\\}'));
  assert(match && match[0].includes('invalidateAuthForm()'), `Missing guarded production setter ${name}`); return match[0];
});
const submit = method('submit');
assert(submit.includes('catch (_: Exception)') && submit.includes('catch (cancel: CancellationException)'), 'V3 submit not placed');
assert(submit.includes('when (submittedMode)') && !submit.includes('catch (_: Throwable)'), 'auth dispatch/fatal contract changed');
assert(submit.includes('activeAuthSubmission === identity') && submit.includes('} finally {'), 'missing V3 independent busy ownership');
assert(!method('invalidateAuthForm').includes('_formState'), 'edits must not enable parallel requests');
const enumMode = source.match(/enum class VortXAccountMode[^\n]+/)?.[0];
const formState = source.match(/sealed interface VortXAccountFormState \{[^]*?\n\}/)?.[0];
const identity = source.match(/    private var authFormIdentity = Any\(\)/)?.[0];
const active = source.match(/    private var activeAuthSubmission: Any\? = null/)?.[0];
const notice = source.match(/        const val AUTH_RETRY_NOTICE = [^\n]+/)?.[0];
assert(enumMode && formState && identity && active && notice, 'missing production type/identities/notice');
const generated = `import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
${enumMode}
${formState}
class QueueDispatcher : CoroutineDispatcher() {
    private val pending = java.util.ArrayDeque<Runnable>()
    override fun dispatch(context: CoroutineContext, block: Runnable) { pending.add(block) }
    fun drain() { while (pending.isNotEmpty()) pending.removeFirst().run() }
}
class RecordingScope(dispatcher: CoroutineDispatcher = Dispatchers.Unconfined) : CoroutineScope {
    val errors = mutableListOf<Throwable>()
    override val coroutineContext = SupervisorJob() + dispatcher + CoroutineExceptionHandler { _, error -> errors.add(error) }
    var last: Job? = null
    var completion: Throwable? = null
    fun launch(action: suspend CoroutineScope.() -> Unit): Job = CoroutineScope(coroutineContext).launch(block = action).also {
        last = it; it.invokeOnCompletion { cause -> completion = cause }
    }
}
class FakeSync {
    var generation = 0
    var session: String? = "original"
    val checkpoint = byteArrayOf(4, 2, 7)
    var checkpointWrites = 0
    var signOutSucceeds = true
    var calls = mutableListOf<VortXAccountMode>()
    var action: suspend () -> Unit = {}
    fun captureLocalLibraryMutationAdmission(): ((() -> Boolean) -> Boolean)? {
        val before = generation
        return { block -> before == generation && block() }
    }
    suspend fun perform(mode: VortXAccountMode) { calls.add(mode); action() }
    fun signOut(): Boolean { generation++; if (!signOutSucceeds) return false; session = null; return true }
}
class Fixture(val sync: FakeSync = FakeSync(), val viewModelScope: RecordingScope = RecordingScope()) {
    val _mode = MutableStateFlow(VortXAccountMode.SIGN_IN)
    val _login = MutableStateFlow("")
    val _username = MutableStateFlow("")
    val _password = MutableStateFlow("")
    val _totp = MutableStateFlow("")
    val _totpRequired = MutableStateFlow(false)
    val _recoveryInput = MutableStateFlow("")
    val _formState = MutableStateFlow<VortXAccountFormState>(VortXAccountFormState.Idle)
    val _showReconcile = MutableStateFlow(false)
    val _recoveryCode = MutableStateFlow<String?>("retained-code")
    val _syncNotice = MutableStateFlow<String?>(null)
${identity}
${active}
    private fun stopQrJoiner() {}
    // Synthetic auth collaborators only: production submit/cleanup/validation/inputs are copied below.
    private suspend fun signIn() { sync.perform(VortXAccountMode.SIGN_IN); clearAuthInputs() }
    private suspend fun register() { sync.perform(VortXAccountMode.REGISTER); clearAuthInputs() }
    private suspend fun recover() { sync.perform(VortXAccountMode.RECOVER); clearAuthInputs() }
${method('invalidateAuthForm')}
${method('onModeChange')}
${setters.join('\n')}
${submit}
${method('validate')}
${method('clearAuthInputs')}
${method('signOut')}
    companion object {
${notice}
        const val MIN_PASSWORD_LENGTH = 8
    }
}
private var cases = 0
private fun case(name: String, body: () -> Unit) { body(); cases++; println("PASS " + name) }
private fun form(f: Fixture = Fixture()): Fixture {
    f.onLoginChange("fixture@example.invalid"); f.onPasswordChange("fixture-password")
    f.onTotpChange("123456"); f.onRecoveryInputChange("fixture-recovery"); return f
}
fun main() {
    case("ordinary exception clears original secrets, fixed retry, no saved-data write") {
        val f = form(); val checkpoint = f.sync.checkpoint.copyOf()
        f.sync.action = { throw IllegalStateException("https://fixture.invalid/?token=private-value") }
        f.submit()
        val error = f._formState.value as VortXAccountFormState.Error
        check(error.message == Fixture.AUTH_RETRY_NOTICE && !error.message.contains("private-value"))
        check(f._password.value.isEmpty() && f._totp.value.isEmpty() && f._recoveryInput.value.isEmpty())
        check(f._login.value == "fixture@example.invalid" && f._recoveryCode.value == "retained-code")
        check(f.sync.session == "original" && f.sync.checkpoint.contentEquals(checkpoint) && f.sync.checkpointWrites == 0)
        check(f.viewModelScope.errors.isEmpty())
    }
    case("input edits do not enable a second request, and old failure preserves edited input") {
        val f = form(); val gate = CompletableDeferred<Unit>()
        f.sync.action = { gate.await(); throw IllegalArgumentException("old") }; f.submit()
        f.onPasswordChange("replacement-password"); check(f._formState.value == VortXAccountFormState.Submitting)
        f.submit(); check(f.sync.calls.size == 1)
        gate.complete(Unit)
        check(f._password.value == "replacement-password" && f._formState.value == VortXAccountFormState.Idle)
    }
    case("explicit mode-change replacement keeps its own active spinner and inputs") {
        val f = form(); val gate = CompletableDeferred<Unit>()
        f.sync.action = { gate.await(); throw IllegalArgumentException("old") }; f.submit()
        f.onModeChange(VortXAccountMode.RECOVER); f.onPasswordChange("replacement-password")
        f.sync.action = { awaitCancellation() }; f.submit(); check(f.sync.calls.size == 2)
        gate.complete(Unit)
        check(f._password.value == "replacement-password" && f._formState.value == VortXAccountFormState.Submitting)
        f.viewModelScope.cancel()
    }
    case("form A to B to A does not readmit the old failure") {
        val f = form(); val gate = CompletableDeferred<Unit>()
        f.sync.action = { gate.await(); error("old") }; f.submit()
        f.onPasswordChange("different"); f.onPasswordChange("fixture-password"); gate.complete(Unit)
        check(f._password.value == "fixture-password" && f._formState.value == VortXAccountFormState.Idle)
    }
    case("mode change preserves replacement credentials from old failure") {
        val f = form(); val gate = CompletableDeferred<Unit>()
        f.sync.action = { gate.await(); error("old") }; f.submit()
        f.onModeChange(VortXAccountMode.RECOVER); f.onPasswordChange("recovered-password"); f.onRecoveryInputChange("replacement-recovery")
        gate.complete(Unit)
        check(f._mode.value == VortXAccountMode.RECOVER && f._password.value == "recovered-password" && f._recoveryInput.value == "replacement-recovery")
        check(f._formState.value == VortXAccountFormState.Idle)
    }
    case("post-adoption throw settles original form without resetting adopted account or attributing error") {
        val f = form()
        f.sync.action = { f.sync.generation++; f.sync.session = "adopted"; error("after adoption") }
        f.submit()
        check(f.sync.session == "adopted" && f._password.value.isEmpty() && f._totp.value.isEmpty())
        check(f._formState.value == VortXAccountFormState.Idle && f._syncNotice.value == null)
        check(f._recoveryCode.value == "retained-code" && f.sync.checkpointWrites == 0)
    }
    case("sign-out and replacement input revoke old cleanup") {
        val f = form(); val gate = CompletableDeferred<Unit>()
        f.sync.action = { gate.await(); error("old") }; f.submit()
        f.signOut(); f.onPasswordChange("new signed-out password"); gate.complete(Unit)
        check(f.sync.session == null && f._password.value == "new signed-out password" && f._formState.value == VortXAccountFormState.Idle)
    }
    case("failed sign-out retains old busy completion without clearing its now-revoked input") {
        val f = form(); val gate = CompletableDeferred<Unit>()
        f.sync.action = { gate.await(); error("old") }; f.submit()
        f.sync.signOutSucceeds = false; f.signOut()
        val notice = f._syncNotice.value; check(notice != null && f._formState.value == VortXAccountFormState.Submitting)
        gate.complete(Unit)
        check(f.sync.session == "original" && f._password.value == "fixture-password")
        check(f._formState.value == VortXAccountFormState.Idle && f._syncNotice.value == notice)
    }
    case("queued old mode never sends replacement credentials") {
        val dispatcher = QueueDispatcher(); val f = form(Fixture(viewModelScope = RecordingScope(dispatcher)))
        f.submit(); f.onModeChange(VortXAccountMode.REGISTER); f.onUsernameChange("replacement")
        dispatcher.drain(); check(f.sync.calls.isEmpty())
        f.submit(); dispatcher.drain(); check(f.sync.calls == listOf(VortXAccountMode.REGISTER))
    }
    case("cancellation cleans owned secrets and propagates exact cancellation") {
        val f = form(); val cancellation = CancellationException("synthetic cancellation")
        f.sync.action = { throw cancellation }; f.submit()
        check(f.viewModelScope.completion === cancellation && f.viewModelScope.last!!.isCancelled)
        check(f._password.value.isEmpty() && f._formState.value == VortXAccountFormState.Idle && f.viewModelScope.errors.isEmpty())
    }
    case("late cancellation settles owned busy flag but leaves edited secrets") {
        val f = form(); val gate = CompletableDeferred<Unit>(); val cancellation = CancellationException("old cancellation")
        f.sync.action = { gate.await(); throw cancellation }; f.submit()
        f.onPasswordChange("replacement-password"); gate.complete(Unit)
        check(f.viewModelScope.completion === cancellation && f._password.value == "replacement-password")
        check(f._formState.value == VortXAccountFormState.Idle && f.viewModelScope.errors.isEmpty())
    }
    case("fatal errors are not converted to retry errors") {
        for (fatal in listOf(AssertionError("synthetic"), OutOfMemoryError("synthetic"), StackOverflowError("synthetic"))) {
            val f = form(); f.sync.action = { throw fatal }; f.submit()
            check(f.viewModelScope.errors.single() === fatal && f._formState.value == VortXAccountFormState.Idle)
        }
    }
    println("PASS " + cases + " exact-source submit groups; actual auth lifecycle and full app remain separate gates")
}
`;
await writeFile(output, generated, { flag: 'wx' });
process.stdout.write(`source_sha256=${createHash('sha256').update(source).digest('hex')}\noutput=${output}\n`);
