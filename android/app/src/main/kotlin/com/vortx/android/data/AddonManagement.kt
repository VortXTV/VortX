package com.vortx.android.data

import com.vortx.android.model.InstalledAddon

/** Captured at the user action, before a dialog or dispatcher can select a different owner. */
data class AddonManagementTarget(val owner: ContinueWatchingOwner, val addon: InstalledAddon? = null)

data class AddonManagementAccess(
    val owner: ContinueWatchingOwner,
    val canManageInstalled: Boolean,
    val reason: String? = null,
)

/** Visibility is an overlay; membership actions require the exact engine descriptor, not its label. */
fun requireCurrentAddonTarget(target: AddonManagementTarget, owner: ContinueWatchingOwner, installed: List<InstalledAddon>) {
    check(target.owner == owner) { "Add-on account or profile changed. Reopen this action." }
    target.addon?.let { captured ->
        val current = installed.singleOrNull { it.transportUrl == captured.transportUrl }
        check(current != null && current.rawDescriptorJson == captured.rawDescriptorJson) {
            "Add-on changed or was removed. Reload installed add-ons."
        }
    }
}
