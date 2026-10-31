package com.vortx.android.foryou

/** What Home shows for For You on the active profile. */
data class ForYouUi(
    val enabled: Boolean = false,
    val profileId: String? = null,
    val interests: ForYouInterests? = null,
    /** The exact load rendered when Tune/first-run opens. */
    val openingState: ForYouState? = null,
    /** No interests (skipped or cleared): show the "Tell VortX what you like" invite instead of rows. */
    val showInvite: Boolean = false,
    /** Choices known and never decided on any device: the first-run picker may be offered. */
    val undecided: Boolean = false,
)

/** Pure Home publication projection. Its State carries the immutable command identity/basis. */
internal fun forYouOpeningUi(state: ForYouState, enabled: Boolean, hidden: Boolean): ForYouUi = ForYouUi(
    enabled = enabled,
    profileId = state.profileId,
    interests = state.interests,
    openingState = state.takeIf { enabled },
    showInvite = enabled && (state.interests?.isEmpty ?: true) && !hidden,
    undecided = enabled && state.interests?.decided != true,
)
