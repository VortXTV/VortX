package com.vortx.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.colorResource
import com.vortx.android.R
import com.vortx.android.ui.theme.VortXAccents

@Composable
internal fun AccountStartupLoading() {
    Box(
        modifier = Modifier.fillMaxSize().background(colorResource(R.color.vortx_canvas)),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(color = VortXAccents.default.base)
    }
}
