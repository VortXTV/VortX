package com.vortx.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.vortx.android.model.AuthState
import com.vortx.android.ui.components.PrimaryButton
import com.vortx.android.ui.components.SurfaceCard
import com.vortx.android.ui.theme.VortXIcons
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.SignInFormState

/// The account screen (Settings' Account row destination): sign-in form when signed out, account
/// summary + sign-out when signed in. Driven entirely by [AccountViewModel]'s live [AuthState] --
/// there is no local "am I signed in" flag here, so a sign-in that lands from elsewhere (e.g. the
/// engine restoring a persisted session while this screen happens to be open) reflects immediately.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(viewModel: AccountViewModel, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val authState by viewModel.authState.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Account", style = VortXTheme.type.cardTitle) },
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
                .padding(VortXTheme.spacing.edge),
        ) {
            when (val state = authState) {
                is AuthState.SignedIn -> SignedInCard(state, onSignOut = viewModel::signOut)
                AuthState.SignedOut -> SignInCard(viewModel)
            }
        }
    }
}

@Composable
private fun SignedInCard(state: AuthState.SignedIn, onSignOut: () -> Unit) {
    val colors = VortXTheme.colors
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
                    Text(
                        state.email ?: "Stremio account",
                        style = VortXTheme.type.cardTitle,
                    )
                }
            }
            PrimaryButton(text = "Sign Out", onClick = onSignOut)
        }
    }
}

@Composable
private fun SignInCard(viewModel: AccountViewModel) {
    val email by viewModel.email.collectAsStateWithLifecycle()
    val password by viewModel.password.collectAsStateWithLifecycle()
    val formState by viewModel.formState.collectAsStateWithLifecycle()
    val colors = VortXTheme.colors
    val submitting = formState is SignInFormState.Submitting

    SurfaceCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(VortXTheme.spacing.lg),
            verticalArrangement = Arrangement.spacedBy(VortXTheme.spacing.md),
        ) {
            Text("Sign in to Stremio", style = VortXTheme.type.cardTitle)
            OutlinedTextField(
                value = email,
                onValueChange = viewModel::onEmailChange,
                label = { Text("Email", style = VortXTheme.type.label) },
                singleLine = true,
                enabled = !submitting,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.accent,
                    unfocusedBorderColor = colors.hairline,
                    cursorColor = colors.accent,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = password,
                onValueChange = viewModel::onPasswordChange,
                label = { Text("Password", style = VortXTheme.type.label) },
                singleLine = true,
                enabled = !submitting,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = colors.accent,
                    unfocusedBorderColor = colors.hairline,
                    cursorColor = colors.accent,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            (formState as? SignInFormState.Error)?.let {
                Text(text = it.message, style = VortXTheme.type.body.copy(color = colors.danger))
            }
            PrimaryButton(
                text = if (submitting) "Signing in…" else "Sign In",
                onClick = viewModel::signIn,
                loading = submitting,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
