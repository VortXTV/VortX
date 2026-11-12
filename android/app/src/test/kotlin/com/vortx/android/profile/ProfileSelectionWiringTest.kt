package com.vortx.android.profile

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Source wiring audit complements coordinator tests when a Compose runtime is unavailable. */
class ProfileSelectionWiringTest {
    private fun source(path: String): String = listOf("src/main/kotlin", "app/src/main/kotlin", "android/app/src/main/kotlin")
        .map { File("$it/com/vortx/android/$path") }.first(File::isFile).readText()

    @Test fun `both cold hosts gate content on typed completion and return Back to picker`() {
        val phone = source("ui/VortXApp.kt")
        val tv = source("ui/tv/TvApp.kt")
        assertTrue(phone.contains("WhosWatchingScreen(pickerRoster, onDone = { showWhosWatching = false }, onSelected = {"))
        assertTrue(phone.contains("if (showProfiles) ProfileSelectionOrigin.PROFILE_MANAGEMENT else ProfileSelectionOrigin.PICKER"))
        assertTrue(tv.contains("TvWhosWatching(pickerRoster, onDone = { manualPicker = false },"))
        for (host in listOf(phone, tv)) {
            val selection = host.substringAfter("profileSelection?.let {").substringBefore("// The title currently")
            assertTrue(selection.contains("ProfileSelectionSurface(request, handoff,"))
            assertTrue(selection.contains("return@VortXTheme"))
            assertTrue(selection.contains("onChooseAgain = { profileSelection = null;"))
        }
        for (host in listOf(phone, tv)) {
            assertTrue(host.contains("ProfilePickerAccountHost(syncManager, pickerAccountModel, diagnosticAdmission = ::currentPickerDiagnosticExportAllowed, retirePickerUi = { profileSelection = null }"))
            assertTrue(host.contains("onSignOutRequest = requestSignOut"))
            assertTrue(host.indexOf("ProfilePickerAccountHost(") < (host.indexOf("// The title currently").takeIf { it >= 0 } ?: host.length))
        }
        val accountHost = source("ui/profilepicker/ProfilePickerAccountHost.kt")
        assertTrue(accountHost.contains("model.signOut(original)"))
        assertTrue(accountHost.contains("model.requestClosePickerPresentation()"))
        assertTrue(accountHost.contains("diagnosticAdmission: () -> Boolean"))
        assertTrue(phone.contains("diagnosticAdmission = ::currentPickerDiagnosticExportAllowed"))
        assertTrue(tv.contains("diagnosticAdmission = ::currentPickerDiagnosticExportAllowed"))
        assertFalse(accountHost.contains("UnifiedSignInScreen"))
        assertFalse(accountHost.contains("TvLoginScreen"))
        assertFalse(accountHost.contains("showPicker = false"))
        assertFalse(accountHost.contains("showWhosWatching = false"))
        val surface = source("ui/profilepicker/ProfileSelectionSurface.kt")
        assertTrue(surface.contains("handoff.complete(presentation.request)"))
        assertTrue(surface.contains("BackHandler(onBack = onChooseAgain)"))
        assertTrue(surface.contains("handoff.signIn(request, email, password)"))
    }

    @Test fun `tools wraps only main picker while account and native selection guards remain separate`() {
        for (path in listOf("ui/VortXApp.kt", "ui/tv/TvApp.kt")) {
            val host = source(path)
            assertTrue(host.contains("val pickerToolsModel = rememberPickerToolsModel(syncManager, externalRestore = restoreExclusion)"))
            assertTrue(host.contains("?.pickerAccountFileRestoreExclusion(syncManager)"))
            assertTrue(host.contains("pickerToolsModel.restoreStatusOwner.collectAsStateWithLifecycle()"))
            assertTrue(host.contains("statusOnlyOwner = original, statusOnlyAdmission = statusAdmission"))
            assertTrue(host.contains("(pickerToolsState.open && pickerToolsModel.state.value.open)"))
            assertTrue(host.contains("ProfilePickerToolsHost(pickerToolsModel, isTv ="))
            assertTrue(host.contains("diagnosticAdmission = ::currentPickerDiagnosticExportAllowed"))
            assertTrue(host.contains("pickerToolsState.open"))
        }
        val tools = source("ui/profilepicker/ProfilePickerToolsHost.kt")
        assertTrue(tools.contains("diagnosticAdmission: () -> Boolean"))
        assertTrue(tools.contains("model.destinationReturned(originalRequest, tree)"))
        assertTrue(tools.contains("key(request.routeId, request.operationId)"))
        assertTrue(tools.contains("BackHandler(enabled = state.open"))
        assertTrue(tools.contains("entryFocus.requestFocus()"))
        assertTrue(tools.contains("remember(model, state.routeGeneration) { controller.attachPicker() }"))
        assertTrue(tools.contains("remember(model, attachment, state.presentationId) { controller.renderedActions(attachment) }"))
        assertTrue(tools.contains("onDownload = { actionGrant?.let(controller::download) }"))
        val controller = source("ui/profilepicker/ProfilePickerToolsController.kt")
        val download = controller.substringAfter("fun download(expected: PickerToolsActionGrant)").substringBefore("fun claimDestinationLaunch")
        assertFalse(download.contains("accounts.capture()"))
        assertTrue(controller.contains("route.original?.let(accounts::isCurrent)"))

        assertFalse(tools.contains("onSelected"))
        assertFalse(tools.contains("CreateDocument"))
        val model = source("ui/viewmodel/ProfilePickerToolsViewModel.kt")
        assertTrue(model.contains("manager.capturePickerAccountSnapshot()"))
        assertTrue(model.contains("manager.isPickerAccountCurrent(original)"))
        assertTrue(model.contains("manager.downloadAccountBackupFile(original)"))
        assertTrue(model.contains("shareDiagnosticLog(applicationContext, mayShare = admission)"))
        assertFalse(source("ui/screens/WhosWatchingScreen.kt").contains("DiagnosticLogAction("))
        // The existing account form and settings diagnostics retain their independently legitimate uses.
        assertTrue(source("ui/screens/VortXAccountScreen.kt").contains("DiagnosticLogAction("))
        assertTrue(source("ui/screens/DiagnosticsSettingsScreen.kt").contains("shareDiagnosticLog(context)"))
    }

    @Test fun `restore exclusion is one application binding for the exact attached manager`() {
        val app = source("VortXApplication.kt")
        val binding = "pickerFileRestoreBinding = manager to ApplicationAccountFileRestoreExclusion(this, manager)"
        val attachment = app.indexOf("manager.attachNativeGateway(nativeAccounts)")
        val publication = app.indexOf(binding)
        assertTrue(attachment >= 0 && publication > attachment)
        assertEquals(publication, app.lastIndexOf(binding))
        assertTrue(app.contains("it.first === expected && syncManager === expected"))
        val model = source("ui/viewmodel/ProfilePickerToolsViewModel.kt")
        assertTrue(model.contains("if (manager != null && externalRestore != null)"))
        for (path in listOf("MainActivity.kt", "ui/tv/TvActivity.kt")) {
            val activity = source(path)
            assertTrue(activity.contains("syncManager = app.syncManager"))
            assertFalse(activity.contains("ApplicationAccountFileRestoreExclusion("))
        }
    }

    @Test fun `settings selections preserve typed result to the same host`() {
        assertTrue(source("ui/VortXApp.kt").contains("ProfileSelectionPresentation(it, ProfileSelectionOrigin.PROFILE_MANAGEMENT)"))
        assertTrue(source("ui/VortXApp.kt").contains("onReturnToProfiles = { showProfiles = true }"))
        assertTrue(source("ui/tv/TvShell.kt").contains("onProfileSelected = onProfileSelected"))
        assertTrue(source("ui/tv/TvSettingsScreen.kt").contains("onSelected = onProfileSelected"))
        val gateway = source("ui/tv/TvProfilesScreen.kt")
        assertTrue(gateway.contains("Result<ProfileSelectionRequest>"))
        assertTrue(gateway.contains("captureProfileSelection(store, profile, outcome,"))
        assertTrue(gateway.contains("gateway.select(profile, captured).fold(onSuccess = onSelected"))
        assertFalse(gateway.contains("The current account session remains in use"))
    }

    @Test fun `pending selection survives composition recreation without bypassing native authority`() {
        assertTrue(source("profile/ProfileStore.kt").contains("selectionPending || (profiles.size > 1 && !pickedThisLaunch)"))
        val request = source("profile/ProfileSelectionRequest.kt")
        val store = source("profile/ProfileStore.kt")
        assertTrue(store.contains("selectionPending = true"))
        assertTrue(store.contains("selectionPending = false"))
        assertTrue(request.contains("checkNotNull(nativeAdmission)"))
        assertTrue(request.contains("stillSelected() && admit(store::completePickerSelection)"))
    }

    @Test fun `late admitted roster controls launch while absence never substitutes for signed out`() {
        val account = com.vortx.android.sync.SessionOwnerSnapshot.Account("test-account", 7L)
        val adult = UserProfile(id = "owner", name = "Adult", avatar = "emoji:🎬")
        val child = UserProfile(id = "child", name = "Child", avatar = "emoji:🌸")
        val mount = Any()
        fun roster(profiles: List<UserProfile>, pending: Boolean = false, picked: Boolean = false) =
            AdmittedPickerRoster(mount, account, profiles, adult.id, pending, picked)

        assertEquals(ProfilePickerEntry.UNAVAILABLE, profilePickerEntry(true, false, null))
        assertEquals(ProfilePickerEntry.CONTENT, profilePickerEntry(true, true, null))
        assertEquals(ProfilePickerEntry.CONTENT, profilePickerEntry(true, false, roster(listOf(adult))))
        assertEquals(ProfilePickerEntry.CHOOSE, profilePickerEntry(true, false, roster(listOf(adult, child))))
        assertEquals(ProfilePickerEntry.CONTENT, profilePickerEntry(true, false, roster(listOf(adult, child), picked = true)))
        assertEquals(ProfilePickerEntry.CHOOSE, profilePickerEntry(true, false, roster(listOf(adult), pending = true, picked = true)))
    }

    @Test fun `launch confirmation follows the exact account generation and selected profile`() {
        val account = com.vortx.android.sync.SessionOwnerSnapshot.Account("test-account", 7L)
        val chosen = PickerLaunchSelection(account, "child")
        assertTrue(chosen.matches(account.copy(), "child"))
        assertFalse(chosen.matches(account.copy(generation = 8L), "child"))
        assertFalse(chosen.matches(account.copy(id = "other-account"), "child"))
        assertFalse(chosen.matches(account, "owner"))
    }

    @Test fun `phone and TV hold title delivery until picker return and acknowledge applied detail`() {
        for (path in listOf("ui/VortXApp.kt", "ui/tv/TvApp.kt")) {
            val host = source(path)
            val picker = host.indexOf(if (path == "ui/VortXApp.kt") "if (showAdmittedPicker ||" else "if (showPicker ||")
            val route = host.indexOf("LaunchedEffect(deepLinkEvent, pickerRoster")
            assertTrue(picker >= 0 && route > picker)
            val delivery = host.substring(route, host.indexOf("onDeepLinkHandled(event)", route))
            assertTrue(delivery.contains("event.sequence <= handledDeepLinkSequence"))
            assertTrue(delivery.contains("app?.isPickerRosterCurrent(syncManager, pickerRoster)"))
            assertTrue(delivery.contains("handledDeepLinkSequence = event.sequence"))
        }
    }
}
