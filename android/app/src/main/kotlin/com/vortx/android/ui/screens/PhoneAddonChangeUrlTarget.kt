package com.vortx.android.ui.screens

import com.vortx.android.data.AddonManagementTarget
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.InstalledAddon
import com.vortx.android.ui.viewmodel.AddonsViewModel

/** Called synchronously by the rendered row, before a dialog effect or dispatcher can run. */
internal fun capturePhoneAddonChangeUrlTarget(
    viewModel: AddonsViewModel,
    addon: InstalledAddon,
    renderedOwner: ContinueWatchingOwner,
): AddonManagementTarget? = viewModel.captureManagementTarget(addon, renderedOwner)
