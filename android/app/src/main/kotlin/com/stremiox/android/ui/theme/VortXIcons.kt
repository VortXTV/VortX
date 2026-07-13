package com.stremiox.android.ui.theme

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDownCircle
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.SmartDisplay
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.ui.graphics.vector.ImageVector

/// The one icon set for the whole app (DESIGN-SYSTEM.md §6 "Icons"): a fixed name → glyph mapping so
/// call sites never reach for `Icons.Filled.*` directly (that's how a bare-glyph / inconsistent-weight
/// regression creeps in — §7 anti-pattern "bare text glyphs"). Names below mirror the §6 list; a few
/// (`playRectangle`, `chevronUpDown`, `arrowDownCircle`) use the closest-available Material Symbol
/// since Material's naming doesn't line up 1:1 with SF Symbols — documented per entry.
object VortXIcons {
    /// SF `play.fill` — primary/hero play affordance.
    val playFill: ImageVector = Icons.Filled.PlayArrow

    /// SF `play.circle` — a play affordance inside a badge/circle context (source rows).
    val playCircle: ImageVector = Icons.Filled.PlayCircle

    /// SF `arrow.down.circle` — download / torrent source affordance.
    val arrowDownCircle: ImageVector = Icons.Filled.ArrowDropDownCircle

    /// SF `chevron.up.chevron.down` — a sort/quality-tier disclosure control.
    val chevronUpDown: ImageVector = Icons.Filled.UnfoldMore

    val chevronDown: ImageVector = Icons.Filled.KeyboardArrowDown
    val chevronLeft: ImageVector = Icons.AutoMirrored.Filled.KeyboardArrowLeft

    /// SF `list.bullet` — the all-sources list disclosure.
    val listBullet: ImageVector = Icons.AutoMirrored.Filled.List

    /// SF `play.rectangle` — a 16:9 media/episode-thumb affordance; Material has no rectangle-play
    /// glyph, `SmartDisplay` (a play triangle in a rounded rect) is the closest available shape.
    val playRectangle: ImageVector = Icons.Filled.SmartDisplay

    val bookmark: ImageVector = Icons.Filled.BookmarkBorder
    val bookmarkFill: ImageVector = Icons.Filled.Bookmark
    val share: ImageVector = Icons.Filled.Share
    val starFill: ImageVector = Icons.Filled.Star
    val checkmarkCircle: ImageVector = Icons.Filled.CheckCircle

    // Chrome / nav icons used outside the §6 list but needed by existing screens; kept in the same
    // one-object-no-direct-Icons.Filled discipline.
    val back: ImageVector = Icons.AutoMirrored.Filled.ArrowBack
    val close: ImageVector = Icons.Filled.Close
    val home: ImageVector = Icons.Filled.Home
    val discover: ImageVector = Icons.Filled.Explore
    val library: ImageVector = Icons.Filled.VideoLibrary
    val search: ImageVector = Icons.Filled.Search
    val settings: ImageVector = Icons.Filled.Settings
    val account: ImageVector = Icons.Filled.Person
    val audioOutput: ImageVector = Icons.Filled.GraphicEq
    val subtitles: ImageVector = Icons.Filled.Subtitles
    val download: ImageVector = Icons.Filled.Download

    /// SF `ellipsis` — the visible face of a bulk/overflow menu (S05: the season "…" mark-watched menu).
    val moreHoriz: ImageVector = Icons.Filled.MoreHoriz

    // S04 (Add-ons / Library remove control) additions -- same one-object discipline as above.
    /// SF `trash` — remove/uninstall/delete affordance (Library poster "x", Add-ons "Remove").
    val delete: ImageVector = Icons.Filled.Delete

    /// SF `plus` — add-to-library / install affordance.
    val add: ImageVector = Icons.Filled.Add

    /// SF `puzzlepiece.extension.fill` — default add-on icon when it has no manifest logo.
    val addon: ImageVector = Icons.Filled.Extension
}
