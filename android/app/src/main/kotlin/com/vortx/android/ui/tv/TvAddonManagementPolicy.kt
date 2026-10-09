package com.vortx.android.ui.tv

import com.vortx.android.model.InstalledAddon

internal data class TvAddonManagementActions(
    val configure: Boolean,
    val changeUrl: Boolean,
    val remove: Boolean,
)

/** Shared profiles customize visibility/order; only their add-on owner changes account membership. */
internal fun tvAddonManagementActions(addon: InstalledAddon, canManageInstalled: Boolean) =
    TvAddonManagementActions(
        configure = addon.isConfigurable,
        changeUrl = canManageInstalled && !addon.isProtected && !addon.isOfficial,
        remove = canManageInstalled && !addon.isProtected,
    )

internal enum class TvAddonDialogKind { CHANGE_URL, REMOVE }
