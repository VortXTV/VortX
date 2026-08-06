package com.vortx.android.ui.screens

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.components.Chip
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.VortXAccountFormState
import com.vortx.android.ui.viewmodel.VortXAccountMode
import com.vortx.android.ui.viewmodel.VortXAccountViewModel
import com.vortx.android.ui.viewmodel.VortXQrJoinState

/// The VortX account screen (Settings > VortX Account): sign in / create / recover when signed out;
/// account summary + Sync now + sign out when signed in. This is the surface that finally DRIVES
/// [com.vortx.android.sync.VortXSyncManager] (the audit's unreachable-account gap): every action here
/// goes through [VortXAccountViewModel] into the manager's register / signIn / recover /
/// reconcileAfterSignIn / mergeBoth seams. Signed-in truth is the manager's own account flow, so a
/// session restored at process start shows signed in with no local flag.
///
/// Two one-shot interstitials render INSTEAD of the signed-in card (inline cards, never dialogs, per
/// DESIGN-SYSTEM.md §7): the one-time recovery code after register (shown until explicitly confirmed
/// saved) and the sign-in reconcile question ("this account already has synced data -- keep which
/// side?"), whose three answers map 1:1 onto the manager's merge/pull/push reconcile seams.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VortXAccountScreen(viewModel: VortXAccountViewModel, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val sessionUiState by viewModel.sessionUiState.collectAsStateWithLifecycle()
    val recoveryCode by viewModel.recoveryCode.collectAsStateWithLifecycle()
    val showReconcile by viewModel.showReconcile.collectAsStateWithLifecycle()
    val formState by viewModel.formState.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("VortX Account", style = VortXTheme.type.cardTitle) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(VortXIcons.back, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(VortXTheme.spacing.edge),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            val code = recoveryCode
            if (code != null) {
                RecoveryCodeCard(
                    code = code,
                    warning = (formState as? VortXAccountFormState.Error)?.message,
                    onSaved = viewModel::dismissRecoveryCode,
                )
            } else {
                when (val session = sessionUiState) {
                    VortXSyncManager.SessionUiState.UnknownOrUnavailable ->
                        SessionUnavailableCard(viewModel::retrySessionRestore)
                    VortXSyncManager.SessionUiState.SignedOut -> AuthCard(viewModel)
                    is VortXSyncManager.SessionUiState.SignedIn -> {
                        if (showReconcile) {
                            ReconcileCard(viewModel)
                        } else {
                            SignedInCard(session.account, viewModel)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SessionUnavailableCard(onRetry: () -> Unit) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Secure session unavailable", style = VortXTheme.type.cardTitle)
            Text(
                "VortX could not confirm whether this device is signed in. Your account has not been treated as " +
                    "signed out. Unlock secure storage, then retry.",
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
            PrimaryButton(
                text = "Retry",
                onClick = onRetry,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/// The one-time recovery code, shown exactly once after register until the user confirms they saved
/// it. The code is the ONLY data-preserving way back in after a forgotten password (the account is
/// end-to-end encrypted; there is no server-side reset), so the warning is explicit.
@Composable
private fun RecoveryCodeCard(code: String, warning: String?, onSaved: () -> Unit) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Save your recovery code", style = VortXTheme.type.cardTitle)
            Text(
                "Your account is end-to-end encrypted. If you forget your password, this code is the " +
                    "only way to recover your data. Write it down and store it offline. " +
                    "It will not be shown again.",
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
            Text(
                code,
                style = VortXTheme.type.cardTitle.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier.fillMaxWidth(),
            )
            warning?.let {
                Text(it, style = VortXTheme.type.body.copy(color = colors.danger))
            }
            PrimaryButton(
                text = "I saved my recovery code",
                onClick = onSaved,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/// The sign-in reconcile question. Nothing syncs until one of the three answers is chosen, so the
/// account doc can never be pre-empted by an automatic pull or push (#145 restore-before-push).
@Composable
private fun ReconcileCard(viewModel: VortXAccountViewModel) {
    val colors = VortXTheme.colors
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("This account already has synced data", style = VortXTheme.type.cardTitle)
            Text(
                "Choose what to keep. Merging keeps everything from both this device and your account.",
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
            PrimaryButton(
                text = "Merge both (recommended)",
                onClick = viewModel::reconcileMergeBoth,
                modifier = Modifier.fillMaxWidth(),
            )
            TextAction("Use my account's data", onClick = viewModel::reconcileUseAccount)
            TextAction("Keep this device's data", onClick = viewModel::reconcileKeepDevice)
        }
    }
}

@Composable
private fun SignedInCard(account: VortXSyncManager.Account, viewModel: VortXAccountViewModel) {
    val colors = VortXTheme.colors
    val syncing by viewModel.syncing.collectAsStateWithLifecycle()
    val syncNotice by viewModel.syncNotice.collectAsStateWithLifecycle()
    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(VortXIcons.account, contentDescription = null, tint = colors.accent)
                Column {
                    Text("Signed in", style = VortXTheme.type.label.copy(color = colors.textSecondary))
                    Text(account.username.ifEmpty { account.email }, style = VortXTheme.type.cardTitle)
                }
            }
            Text(account.email, style = VortXTheme.type.body.copy(color = colors.textSecondary))
            Text(
                "Profiles and watch progress sync to your other devices automatically. " +
                    "Everything is end-to-end encrypted.",
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
            syncNotice?.let {
                Text(it, style = VortXTheme.type.label.copy(color = colors.textSecondary))
            }
            PrimaryButton(
                text = if (syncing) "Syncing…" else "Sync now",
                onClick = viewModel::syncNow,
                loading = syncing,
                modifier = Modifier.fillMaxWidth(),
            )
            TextAction("Sign Out", onClick = viewModel::signOut, danger = true)
        }
    }
}

/// Signed-out: the mode switcher (Sign in / Create / Recover) over the active mode's fields. All
/// three flows submit through the ONE primary button (§1 "One primary action").
@Composable
private fun AuthCard(viewModel: VortXAccountViewModel) {
    val colors = VortXTheme.colors
    val mode by viewModel.mode.collectAsStateWithLifecycle()
    val login by viewModel.login.collectAsStateWithLifecycle()
    val username by viewModel.username.collectAsStateWithLifecycle()
    val password by viewModel.password.collectAsStateWithLifecycle()
    val totp by viewModel.totp.collectAsStateWithLifecycle()
    val recoveryInput by viewModel.recoveryInput.collectAsStateWithLifecycle()
    val formState by viewModel.formState.collectAsStateWithLifecycle()
    val totpRequired by viewModel.totpRequired.collectAsStateWithLifecycle()
    val qrJoinState by viewModel.qrJoinState.collectAsStateWithLifecycle()
    val submitting = formState is VortXAccountFormState.Submitting

    LaunchedEffect(mode) {
        if (mode == VortXAccountMode.SIGN_IN) viewModel.startQrJoiner() else viewModel.stopQrJoiner()
    }
    DisposableEffect(viewModel) {
        onDispose(viewModel::stopQrJoiner)
    }

    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text(
                when (mode) {
                    VortXAccountMode.SIGN_IN -> "Sign in to VortX"
                    VortXAccountMode.REGISTER -> "Create your VortX account"
                    VortXAccountMode.RECOVER -> "Recover your account"
                },
                style = VortXTheme.type.cardTitle,
            )
            Text(
                "One account for every device. Profiles and watch progress sync end-to-end encrypted; " +
                    "only your devices can read them.",
                style = VortXTheme.type.body.copy(color = colors.textSecondary),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(VortXTheme.spacing.xs)) {
                Chip("Sign in", selected = mode == VortXAccountMode.SIGN_IN, enabled = !submitting,
                    onClick = { viewModel.onModeChange(VortXAccountMode.SIGN_IN) })
                Chip("Create", selected = mode == VortXAccountMode.REGISTER, enabled = !submitting,
                    onClick = { viewModel.onModeChange(VortXAccountMode.REGISTER) })
                Chip("Recover", selected = mode == VortXAccountMode.RECOVER, enabled = !submitting,
                    onClick = { viewModel.onModeChange(VortXAccountMode.RECOVER) })
            }
            if (mode == VortXAccountMode.SIGN_IN) {
                QrJoinerBlock(qrJoinState, viewModel::retryQrJoiner)
                Text(
                    "or sign in with your password",
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                )
            }
            FormField(
                value = login,
                onValueChange = viewModel::onLoginChange,
                label = if (mode == VortXAccountMode.SIGN_IN) "Email or username" else "Email",
                keyboardType = KeyboardType.Email,
                enabled = !submitting,
            )
            if (mode == VortXAccountMode.REGISTER) {
                FormField(
                    value = username,
                    onValueChange = viewModel::onUsernameChange,
                    label = "Username",
                    enabled = !submitting,
                )
            }
            if (mode == VortXAccountMode.RECOVER) {
                FormField(
                    value = recoveryInput,
                    onValueChange = viewModel::onRecoveryInputChange,
                    label = "Recovery code",
                    enabled = !submitting,
                )
            }
            FormField(
                value = password,
                onValueChange = viewModel::onPasswordChange,
                label = if (mode == VortXAccountMode.RECOVER) "New password" else "Password",
                keyboardType = KeyboardType.Password,
                password = true,
                enabled = !submitting,
            )
            if (mode == VortXAccountMode.SIGN_IN && totpRequired) {
                FormField(
                    value = totp,
                    onValueChange = viewModel::onTotpChange,
                    label = "6-digit code",
                    keyboardType = KeyboardType.Number,
                    enabled = !submitting,
                )
                Text(
                    "Two-factor authentication is on for this account. Enter the code from your authenticator app.",
                    style = VortXTheme.type.label.copy(color = colors.textSecondary),
                )
            }
            (formState as? VortXAccountFormState.Error)?.let {
                Text(it.message, style = VortXTheme.type.body.copy(color = colors.danger))
            }
            PrimaryButton(
                text = when {
                    submitting -> "Working…"
                    mode == VortXAccountMode.SIGN_IN -> "Sign In"
                    mode == VortXAccountMode.REGISTER -> "Create Account"
                    else -> "Reset Password"
                },
                onClick = viewModel::submit,
                loading = submitting,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun QrJoinerBlock(state: VortXQrJoinState, onRetry: () -> Unit) {
    val colors = VortXTheme.colors
    val qrSize = if (LocalConfiguration.current.screenWidthDp >= 800) 320.dp else 232.dp
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.sm),
    ) {
        when (state) {
            VortXQrJoinState.Idle -> {
                Text("Sign in without typing on this device.", style = VortXTheme.type.body)
                TextAction("Prepare sign-in code", onClick = onRetry)
            }
            VortXQrJoinState.Starting ->
                Text("Preparing your sign-in code...", style = VortXTheme.type.body)
            is VortXQrJoinState.Waiting -> {
                val bitmap = remember(state.approvalUrl) { makeQrBitmap(state.approvalUrl) }
                bitmap?.let {
                    Image(
                        bitmap = it.asImageBitmap(),
                        contentDescription = "VortX account sign-in QR code",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .size(qrSize)
                            .background(Color.White)
                            .padding(VortXTheme.spacing.sm),
                    )
                }
                Text(
                    state.code,
                    style = VortXTheme.type.cardTitle.copy(fontFamily = FontFamily.Monospace),
                )
                Text(
                    "Scan the code, or go to vortx.tv/approve and enter it, on a phone or browser signed in to VortX.",
                    style = VortXTheme.type.body.copy(color = colors.textSecondary),
                )
                if (state.reachTrouble) {
                    Text(
                        "Trouble reaching VortX. Still trying...",
                        style = VortXTheme.type.label.copy(color = colors.danger),
                    )
                }
            }
            is VortXQrJoinState.SignedIn -> Text(
                if (state.email.isBlank()) "Signed in to VortX" else "Signed in as ${state.email}",
                style = VortXTheme.type.body.copy(color = colors.accent),
            )
            VortXQrJoinState.Failed -> {
                Text(
                    "That sign-in did not complete. Try again.",
                    style = VortXTheme.type.body.copy(color = colors.danger),
                )
                TextAction("Try again", onClick = onRetry)
            }
        }
    }
}

private fun makeQrBitmap(value: String): Bitmap? = runCatching {
    val matrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 512, 512)
    val pixels = IntArray(matrix.width * matrix.height)
    for (y in 0 until matrix.height) {
        for (x in 0 until matrix.width) {
            pixels[y * matrix.width + x] = if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE
        }
    }
    Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
}.getOrNull()

/// The themed text field every form row here uses (same colors as the other settings forms).
@Composable
private fun FormField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    enabled: Boolean,
    keyboardType: KeyboardType = KeyboardType.Text,
    password: Boolean = false,
) {
    val colors = VortXTheme.colors
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label, style = VortXTheme.type.label) },
        singleLine = true,
        enabled = enabled,
        visualTransformation = if (password) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.accent,
            unfocusedBorderColor = colors.hairline,
            cursorColor = colors.accent,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}

/// A quiet inline text action (the screen's ONE gold CTA stays the PrimaryButton above it).
@Composable
private fun TextAction(text: String, onClick: () -> Unit, danger: Boolean = false) {
    val colors = VortXTheme.colors
    Text(
        text,
        style = VortXTheme.type.body.copy(color = if (danger) colors.danger else colors.accent),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = VortXTheme.spacing.xs),
    )
}
