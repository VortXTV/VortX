package com.vortx.android.ui.tv

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Render wiring supplements the executed policy/VM/native actions; labels alone are not acceptance. */
class TvAddonManagementContractTest {
    @Test fun `TV rendered controls dispatch the shared confirmed actions`() {
        val screen = read("ui/tv/TvAddonsScreen.kt")
        val dialog = read("ui/tv/TvAddonManagementDialog.kt")
        assertTrue(contract(screen, dialog))
        for (mutated in listOf(
            screen.replace("viewModel.install(renderedOwner)", "Unit"),
            screen.replace("viewModel::confirmUpdate", "{}"),
            screen.replace("viewModel.changeAddonUrl(target, replacementUrl)", "Unit"),
            screen.replace("viewModel.remove(target)", "Unit"),
            screen.replace("viewModel.captureManagementTarget(addon, renderedOwner)", "null"),
            screen.replace("viewModel.install(renderedOwner)", "viewModel.install()"),
            screen.replace("viewModel.captureManagementTarget(addon, renderedOwner)", "viewModel.captureManagementTarget(addon)"),
            screen.replace("val renderedOwner = access.owner", "val renderedOwner get() = access.owner"),
            screen.replace("tvAddonManagementActions(addon, access.canManageInstalled)", "tvAddonManagementActions(addon, true)"),
        )) assertFalse(contract(mutated, dialog))
        assertFalse(contract(screen, dialog.replace("BackHandler(onBack = onDismiss)", "BackHandler(onBack = onConfirm)")))
        assertFalse(contract(screen, dialog.replace("cancelFocus.requestFocus()", "inputFocus.requestFocus()")))
    }

    @Test fun `TV preserves QR configure discover and per profile order visibility`() {
        val screen = read("ui/tv/TvAddonsScreen.kt")
        for (token in listOf("TvAddonConfigureDialog", "onClick = onInstallByQr", "onClick = onDiscover",
            "viewModel.toggleAddon(addon, renderedOwner)", "viewModel.applyOrder(result.order, renderedOwner)", "key = InstalledAddon::transportUrl",
            "changeFocus.requestFocus()", "removeFocus.requestFocus()", "backFocus.requestFocus()")) assertTrue(token, screen.contains(token))
    }

    private fun contract(screen: String, dialog: String) = listOf(
        "val renderedOwner = access.owner", "TvAddonUrlField(urlInput, viewModel::onUrlChange", "viewModel.install(renderedOwner)", "pendingUpdate != null",
        "viewModel::confirmUpdate", "viewModel::cancelUpdate", "viewModel.captureManagementTarget(addon, renderedOwner)",
        "viewModel.changeAddonUrl(target, replacementUrl)", "viewModel.remove(target)",
        "tvAddonManagementActions(addon, access.canManageInstalled)", "access.reason",
    ).all(screen::contains) && listOf("OutlinedTextField(", "Dialog(onDismissRequest = onDismiss)",
        "BackHandler(onBack = onDismiss)", "cancelFocus.requestFocus()", "enabled = !busy && confirmEnabled").all(dialog::contains)

    private fun read(relative: String): String = listOf(File("src/main/kotlin/com/vortx/android/$relative"),
        File("app/src/main/kotlin/com/vortx/android/$relative"), File("android/app/src/main/kotlin/com/vortx/android/$relative"))
        .first(File::isFile).readText()
}
