package com.vortx.android.ui.screens

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source wiring proof only; the companion target tests execute the actual capture/VM boundary. */
class PhoneAddonChangeUrlContractTest {
    @Test fun `phone renders a plain owner snapshot and retains the tap target through the dialog`() {
        assertTrue(contract(source()))
    }

    @Test fun `dynamic delegated owner and ownerless dialog effect or submit violate the contract`() {
        val original = source()
        val mutations = listOf(
            original.replace("capturePhoneAddonChangeUrlTarget(viewModel, addon, renderedOwner)",
                "capturePhoneAddonChangeUrlTarget(viewModel, addon, access.owner)"),
            original.replace("val renderedOwner = access.owner", "val renderedOwner get() = access.owner"),
            original.replace("viewModel.onChangeUrlOpen(target)", "viewModel.onChangeUrlOpen()"),
            original.replace("viewModel.changeAddonUrl(target, url)", "viewModel.changeAddonUrl(addon, url)"),
            original.replace("mutableStateOf<AddonManagementTarget?>(null)", "mutableStateOf<InstalledAddon?>(null)"),
        )
        mutations.forEachIndexed { index, mutation -> assertFalse("Mutation $index survived", contract(mutation)) }
    }

    private fun contract(source: String): Boolean =
        source.contains("val access by viewModel.managementAccess.collectAsStateWithLifecycle()") &&
            source.contains("val renderedOwner = access.owner") &&
            source.contains("mutableStateOf<AddonManagementTarget?>(null)") &&
            source.contains("capturePhoneAddonChangeUrlTarget(viewModel, addon, renderedOwner)") &&
            source.contains("changeUrlTarget = it") &&
            source.contains("LaunchedEffect(target) { viewModel.onChangeUrlOpen(target) }") &&
            source.contains("viewModel.changeAddonUrl(target, url)") &&
            source.contains("remember(target) { mutableStateOf(addon.transportUrl) }")

    private fun source(): String {
        val path = "src/main/kotlin/com/vortx/android/ui/screens/AddonsScreen.kt"
        return listOf(File(path), File("app/$path"), File("android/app/$path"))
            .firstOrNull(File::isFile)?.readText() ?: error("Cannot locate $path")
    }
}
