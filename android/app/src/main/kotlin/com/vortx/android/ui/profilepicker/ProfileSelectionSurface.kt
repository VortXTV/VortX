package com.vortx.android.ui.profilepicker

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.data.AuthRepository
import com.vortx.android.model.AuthState
import com.vortx.android.profile.ProfileSelectionHandoff
import com.vortx.android.profile.ProfileSelectionRequest
import com.vortx.android.ui.screens.AccountContent
import com.vortx.android.ui.theme.VortXTheme
import com.vortx.android.ui.viewmodel.AccountViewModel
import com.vortx.android.ui.viewmodel.rememberReplacingViewModelStoreOwner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/** Opaque account handoff surface; Back always returns to the PIN-owning picker. */
@Composable
internal fun ProfileSelectionSurface(
    request: ProfileSelectionRequest,
    handoff: ProfileSelectionHandoff,
    onComplete: () -> Unit,
    onChooseAgain: () -> Unit,
) {
    val state by handoff.state.collectAsStateWithLifecycle()
    val route = remember(request) { UUID.randomUUID().toString() }
    val owner = rememberReplacingViewModelStoreOwner(route)
    val formAuth = remember(request, handoff) { object : AuthRepository {
        override val authState = MutableStateFlow<AuthState>(AuthState.SignedOut).asStateFlow()
        override suspend fun signIn(email: String, password: String) = handoff.signIn(request, email, password)
        override suspend fun signOut() = Unit
    } }
    val account: AccountViewModel = viewModel(viewModelStoreOwner = owner, factory = object : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AccountViewModel(formAuth) as T
    })
    LaunchedEffect(request) { handoff.select(request) }
    LaunchedEffect(state) { if (state == ProfileSelectionHandoff.State.COMPLETE && handoff.complete(request)) onComplete() }
    BackHandler(onBack = onChooseAgain)
    Column(Modifier.fillMaxSize().background(VortXTheme.colors.canvas).verticalScroll(rememberScrollState()).padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text(request.profile.name.ifBlank { "Profile" }, style = VortXTheme.type.screenTitle)
        when (state) {
            ProfileSelectionHandoff.State.WORKING, ProfileSelectionHandoff.State.COMPLETE ->
                Text("Opening your profile…", style = VortXTheme.type.body)
            ProfileSelectionHandoff.State.SIGN_IN, ProfileSelectionHandoff.State.FAILED -> {
                Text(if (!handoff.canSignIn) "The profile changed. Choose it again."
                    else if (state == ProfileSelectionHandoff.State.FAILED)
                    "This profile's account could not be opened. Sign in again, or choose another profile."
                    else "Sign in to the account connected to this profile.", style = VortXTheme.type.body)
                if (handoff.canSignIn) AccountContent(account, Modifier.widthIn(max = 560.dp).fillMaxWidth())
            }
        }
        TextButton(onClick = onChooseAgain) { Text("Choose a profile") }
    }
}
