package com.vortx.android.person

/// Person + credits models for the Android cast/person feature, ported from the Apple
/// `TMDBClient.CastMember` / `TMDBClient.PersonDetail` shapes (`app/SourcesShared/TMDBClient.swift`)
/// and the `PersonView` seed (`app/SourcesShared/PersonView.swift`). Kept in their own `person/`
/// package so they never collide with `model/Media.kt` (owned in part by the media-servers wave); the
/// filmography grid reuses the existing [com.vortx.android.model.MetaItem] card model rather than
/// introducing a parallel preview type.

/// One cast entry for the detail page's full-cast rail: the TMDB person id, the person, the character
/// they played, and a w185 headshot URL when TMDB has one. A REAL TMDB person id ([id] > 0) is what
/// makes the tile tappable through to the [com.vortx.android.ui.screens.PersonScreen]; the meta's
/// plain-name fallback carries no person to look up (see the detail screen's fallback path), so this
/// type is only ever produced from a genuine TMDB credits response.
data class CastMember(
    val id: Int,
    val name: String,
    val character: String?,
    val profileUrl: String?,
) {
    /// A real TMDB person id (the credits endpoint always carries one) means the Person page can be
    /// opened for this member; a non-positive id means "no person to look up" -> render a plain tile.
    val isTappable: Boolean get() = id > 0
}

/// A cast member's biographical detail for the Person page header, ported from the Apple
/// `TMDBClient.PersonDetail`: name, a biography paragraph, a prettified birthday, birthplace, a larger
/// headshot (w342), and the department TMDB best-knows them for ("Acting", "Directing"). Every field
/// past [name] is optional and simply omitted from the header when TMDB has no value.
data class PersonDetail(
    val name: String,
    val biography: String?,
    val birthday: String?, // already prettified ("Mar 1, 1970")
    val placeOfBirth: String?,
    val profileUrl: String?, // w342 headshot, null when TMDB has none
    val knownForDepartment: String?,
)

/// The instant-paint seed the detail cast tile hands the Person page so its header (name + headshot)
/// renders the moment the page appears, before the fuller [PersonDetail] streams in -- the direct
/// mirror of `PersonView(personID:name:profileURL:)`'s seed init on Apple. [id] is the TMDB person id
/// the page fetches its bio + filmography from.
data class PersonSeed(
    val id: Int,
    val name: String,
    val profileUrl: String?,
)
