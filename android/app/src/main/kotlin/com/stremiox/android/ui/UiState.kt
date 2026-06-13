package com.stremiox.android.ui

/// One-way UI state for a screen's content. Screens render exhaustively over this, so loading and
/// error are first-class — not swallowed with a silent default the way an inline repository call
/// would. The engine impl surfaces real add-on failures through [Error] with no UI change.
sealed interface UiState<out T> {
    data object Loading : UiState<Nothing>
    data class Success<out T>(val data: T) : UiState<T>
    data class Error(val message: String) : UiState<Nothing>
}
