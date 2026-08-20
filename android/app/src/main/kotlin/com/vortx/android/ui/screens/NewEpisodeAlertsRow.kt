package com.vortx.android.ui.screens

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.vortx.android.notifications.NewEpisodeNotifications

/**
 * The phone Settings "New episode alerts" toggle. Persists on the shared Apple key
 * [NewEpisodeNotifications.ENABLED_KEY] and, on enable, arms the sweep and requests the runtime
 * POST_NOTIFICATIONS permission (API 33+) in context, mirroring Apple's `setEnabled` requesting
 * authorization the first time alerts are turned on. A denial does not flip the toggle back: the sweep still
 * runs, the alert simply is not shown (the same rule the downloads notification follows).
 */
@Composable
internal fun NewEpisodeAlertsRow() {
    val appContext = LocalContext.current.applicationContext
    var enabled by remember { mutableStateOf(NewEpisodeNotifications.isEnabled(appContext)) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* granted or not, the schedule already stands; the post is permission-gated at fire time */ }
    ToggleRow(
        label = "New episode alerts",
        detail = "Get notified when a series in your Library has a new episode.",
        checked = enabled,
        onCheckedChange = { next ->
            enabled = next
            NewEpisodeNotifications.setEnabled(appContext, next)
            if (next && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        },
    )
}
