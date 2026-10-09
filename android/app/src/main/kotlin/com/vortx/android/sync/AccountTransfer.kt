package com.vortx.android.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class AccountTransferDirection { BACKUP, RESTORE }
enum class AccountTransferChoice { KEEP_DEVICE, USE_ACCOUNT, MERGE }
enum class AccountTransferStage { IDLE, SIGN_IN, CHECKING, CHOOSE, RUNNING, COMPLETE, FAILED }
data class AccountTransferState(
    val direction: AccountTransferDirection? = null,
    val stage: AccountTransferStage = AccountTransferStage.IDLE,
    val message: String? = null,
    val canKeepDevice: Boolean = true,
)

/** One captured account/profile context. Implementations must reject a retired session at dispatch. */
internal interface AccountTransferSession {
    enum class Probe { EMPTY, HAS_DATA, UNAVAILABLE }
    fun isCurrent(): Boolean
    fun hasPendingChanges(): Boolean = false
    fun canKeepDevice(): Boolean = true
    suspend fun probe(): Probe
    suspend fun seed(): Boolean
    suspend fun keepDevice(): Boolean
    suspend fun restore(): Boolean
    suspend fun merge(): Boolean
    fun resumeSync(): Boolean
    fun abandon() = Unit
}

/** Production transfer flow shared by QR approval and an already signed-in TV. No probe writes data. */
internal class AccountTransferController(private val capture: () -> AccountTransferSession?) {
    private val mutable = MutableStateFlow(AccountTransferState())
    val state = mutable.asStateFlow()
    private var session: AccountTransferSession? = null
    private var revision = 0L
    val requestToken: Long get() = revision

    fun prepare(direction: AccountTransferDirection) {
        session?.abandon()
        revision++
        session = null
        mutable.value = AccountTransferState(direction, AccountTransferStage.SIGN_IN)
    }

    fun cancel() {
        session?.abandon()
        revision++
        session = null
        mutable.value = AccountTransferState()
    }

    suspend fun authenticated(expectedToken: Long = revision) {
        if (expectedToken != revision) return
        if (mutable.value.stage != AccountTransferStage.SIGN_IN) return
        val direction = mutable.value.direction ?: return
        val captured = capture() ?: return fail("Your account or profile is unavailable. Reopen this transfer after signing in.")
        session = captured
        val ticket = revision
        mutable.value = AccountTransferState(direction, AccountTransferStage.CHECKING)
        val probe = try { captured.probe() }
        catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { AccountTransferSession.Probe.UNAVAILABLE }
        if (ticket != revision) return
        if (!captured.isCurrent()) return fail("The account or profile changed. Start again for the current account.")
        when (probe) {
            AccountTransferSession.Probe.UNAVAILABLE -> fail("Account data could not be checked. Nothing was transferred. Try again.")
            AccountTransferSession.Probe.EMPTY -> {
                if (direction == AccountTransferDirection.RESTORE) {
                    fail("This account has no backup to restore. This device's data was kept.")
                } else if (!captured.canKeepDevice()) {
                    fail("There is no account-owned data on this device to back up. This account has no saved backup to restore. Sign out or use the account setup flow.")
                } else {
                    // The viewer explicitly selected Back up, and an authenticated read proved empty.
                    runChoice(captured, AccountTransferChoice.KEEP_DEVICE, ticket, emptyAccount = true)
                }
            }
            AccountTransferSession.Probe.HAS_DATA -> {
                // Neither backup nor restore changes either side until the viewer confirms the direction.
                mutable.value = AccountTransferState(direction, AccountTransferStage.CHOOSE, canKeepDevice = captured.canKeepDevice())
            }
        }
    }

    suspend fun choose(choice: AccountTransferChoice) {
        if (mutable.value.stage != AccountTransferStage.CHOOSE) return
        val captured = session ?: return
        if (!captured.isCurrent()) return fail("The account or profile changed. Start again for the current account.")
        if (choice == AccountTransferChoice.KEEP_DEVICE && !captured.canKeepDevice()) {
            mutable.value = mutable.value.copy(message = "No local data belongs to this account yet. Restore account data or Merge both to continue.")
            return
        }
        if (choice == AccountTransferChoice.USE_ACCOUNT && captured.hasPendingChanges()) {
            mutable.value = mutable.value.copy(message = "This device has unsynced changes. Choose Keep this device or Merge both before restoring account data.")
            return
        }
        runChoice(captured, choice, revision)
    }

    private suspend fun runChoice(captured: AccountTransferSession, choice: AccountTransferChoice, ticket: Long, emptyAccount: Boolean = false) {
        mutable.value = mutable.value.copy(stage = AccountTransferStage.RUNNING, message = null)
        val success = try {
            when (choice) {
                AccountTransferChoice.KEEP_DEVICE -> if (emptyAccount) captured.seed() else captured.keepDevice()
                AccountTransferChoice.USE_ACCOUNT -> captured.restore()
                AccountTransferChoice.MERGE -> captured.merge()
            }
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { false }
        if (ticket != revision) return
        if (!success) return fail("The transfer could not be confirmed. Your saved data remains preserved; check the account before retrying.")
        if (!captured.resumeSync()) return fail("The transfer could not be finalized. Reopen Backup & Restore to confirm your account's saved data.")
        mutable.value = mutable.value.copy(stage = AccountTransferStage.COMPLETE, message = when (choice) {
            AccountTransferChoice.KEEP_DEVICE -> "This device's data was backed up to your account."
            AccountTransferChoice.USE_ACCOUNT -> "Account data was restored to this device."
            AccountTransferChoice.MERGE -> "Device and account data were merged and synced."
        })
    }

    private fun fail(message: String) {
        mutable.value = mutable.value.copy(stage = AccountTransferStage.FAILED, message = message)
    }
}
