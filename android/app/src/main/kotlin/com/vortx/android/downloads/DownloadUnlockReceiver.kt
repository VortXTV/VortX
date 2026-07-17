package com.vortx.android.downloads

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Auto-recovery for downloads parked by a locked-write failure (#132): the Android counterpart of Apple's
 * `protectedDataDidBecomeAvailable` observer.
 *
 * THE #132 LESSON, restated for this platform: a download that finishes while the device is locked must PARK and
 * recover on unlock, never dead-end at "couldn't save". Apple hits this constantly, because its default
 * file-protection class makes app files unwritable whenever the SCREEN is locked, so an overnight multi-GB transfer
 * routinely completes into a wall. Android's exposure is genuinely narrower -- app-private storage is
 * credential-encrypted and stays writable once the user has unlocked ONCE since boot -- so the two windows that
 * remain are:
 *
 *  * `ACTION_BOOT_COMPLETED` territory: the device rebooted (an OS update, a flat battery) and a revived transfer
 *    ran before the first unlock.
 *  * `ACTION_USER_UNLOCKED`: a work / secondary profile that locked independently while the device stayed on. This
 *    is the closest Android has to iOS's screen-lock case, and it is why the receiver listens for it rather than
 *    only for boot.
 *
 * Registered in the MANIFEST rather than at runtime, deliberately: the whole point is to recover a download whose app
 * process is long gone, so a receiver that only exists while the app is alive would miss precisely the case it is for.
 * That is also why [DownloadManager]'s parked set is persisted rather than in-memory like Apple's -- this receiver
 * routinely runs in a fresh process with nothing in memory.
 *
 * [DownloadManager.retryDownloadsAwaitingUnlock] no-ops when nothing is parked (the common case) or when the user is
 * still locked, so an ordinary boot pays a prefs read and nothing else.
 */
class DownloadUnlockReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_USER_UNLOCKED && action != Intent.ACTION_BOOT_COMPLETED) return

        // goAsync() buys this receiver time beyond onReceive's ~10s main-thread budget: the retry reads prefs, reads
        // the index off disk, and enqueues work, none of which belongs on the main thread.
        val pending = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            try {
                DownloadStore.init(appContext)
                DownloadManager.init(appContext)
                DownloadManager.retryDownloadsAwaitingUnlock()
            } catch (error: Throwable) {
                // Fail-soft: a parked record stays PAUSED and resumable by hand, which is exactly Apple's
                // cold-relaunch fallback. Never let a recovery attempt crash the boot broadcast.
                Log.w(TAG, "unlock retry failed; parked downloads stay paused and resumable", error)
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        const val TAG = "downloads"
    }
}
