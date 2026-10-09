package com.vortx.android.ui.tv

import com.vortx.android.model.AuthState
import com.vortx.android.sync.VortXSyncManager

internal fun tvBrowseSignedIn(auth: AuthState, session: VortXSyncManager.SessionUiState?): Boolean =
    auth is AuthState.SignedIn || session is VortXSyncManager.SessionUiState.SignedIn
