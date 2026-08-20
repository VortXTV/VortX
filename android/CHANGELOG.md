# VortX Android Changelog

Notable Android changes, newest first. VortX Android is in active development on the shared engine. The
Apple release notes live in the repository [CHANGELOG.md](../CHANGELOG.md).

## Unreleased

### Android TV

**A living hero across Home, Discover, and Library.** The big cinematic banner now follows whatever you point
at and fills in the moment focus lands: it seeds the focused title's backdrop and, a beat later, enriches it
with the clearlogo, synopsis, rating, and genres, then eases a muted trailer in over the still art once one is
found. The trailer plays through the same trailer path the rest of the app uses, so nothing new is fetched to
make it work, and titles without a trailer simply keep their slow-panning backdrop.

**Discover gets the Collections hub and a focus hero.** The Discover tab now leads with the same Collections
band the Home tab has (curated Discover lists, streaming services, and genres), and the hero above the grid
tracks the poster you are on. Opening a collection browses it full-screen with categories and load-more,
exactly like Home.

**A deeper Library on the couch.** The Library adds a focus hero, a type bar that breaks out an Anime segment
(shows and movies from anime catalogs get their own tab), smart filters for Unwatched, In Progress, Watched,
and Short that appear only when they would actually narrow your saved titles, and a press-and-hold menu on any
poster to Mark as Watched, Mark as Unwatched, or Remove from Library.

**Full TV settings, on the same keys as everywhere else.** Android TV Settings now reaches the deep
configuration surfaces from the couch, each one the exact phone screen behind a D-pad route so a change here
writes the identical setting the phone and Apple write: Theme and text size (accent, OLED black, app language,
text size), Home and Discover (rows, collections hub, spoiler-safe mode), Media servers (Plex, Jellyfin,
Emby), Live TV (M3U and Xtream playlists), Source ranking (quality preset, type priority, size cap, min and
max quality, add-on order, regex, stated quality), and All playback settings (still watching prompt and
threshold, seek step, default volume, subtitles, and more). A new Match Frame Rate toggle finally lets the TV
switch to a video's refresh rate so 24p film runs judder-free, and a Community scrub previews toggle lets you
share anonymized scrub thumbnails so titles get instant previews for everyone. A Diagnostics screen shows app,
device, and engine info for support, and a search field at the top of Settings filters the list.

**Back up and restore on a TV, no file picker.** A new Backup and Restore screen signs this TV into your VortX
account by scanning a code (or entering it at vortx.tv/approve) on a signed-in phone or browser, so your
profiles, add-ons, library, and settings are stored in your account, end-to-end encrypted, and restored on any
device you sign in. Nothing is written to a file and your account token never leaves the device.

### Sources and debrid

**Browse and play your debrid cloud, no add-on needed.** A new Settings > Debrid > Your cloud screen lists
what is already sitting in your connected debrid accounts (finished torrents and stored files on Real-Debrid,
AllDebrid, Premiumize, and TorBox) and plays a chosen item straight through the normal player. Nothing is
re-downloaded and no add-on is involved: VortX reads each account's own library, resolves the pick to a
direct link on demand, and hands it to the player. A provider with no key is simply absent, and a file that
has expired from your cloud shows an inline notice instead of a dead player. Android phone.

**Smart source selection, with a live preview.** The Sources settings now lead with a chip panel that turns
each source rule into a visible Only / Avoid chip (Cached, HDR / DV, My audio, Stated quality, Dead swarms,
AV1), plus how excluded sources behave (hide or rank down) and the auto-pick toggle, matching the Apple app.
A live preview under the chips shows which sources your current rules would surface and how many they would
hide, computed with the exact same ranking VortX uses on a real title, so you can see what a rule does before
you open anything. The chips write the same settings the detailed controls did, so nothing you set before
moves.

**Steadier debrid and TorBox search under load.** A provider that has just answered a rate limit or gone
unreachable is now remembered across the whole app, so moving between titles no longer re-fires a request a
provider already refused; a single blip still self-heals on the next try, while a real rate limit backs off
before probing again. TorBox search also falls back to the healthy account host when the public search index
is unreachable, so a TorBox user still gets torrent sources instead of a silent nothing.

### Player

**Player settings and behaviour now match the Apple app.** A wave of playback-parity work brings the phone
player in line with the Apple app, on the same setting keys so a choice made on Apple or the web takes
effect here too:

- **Still watching?** After a long idle stretch, or after several episodes auto-play back-to-back, the
  player pauses and asks whether you are still watching, so an all-night binge does not run on unwatched.
  Continue keeps going; Stop leaves the player. New under Settings > Playback, with a toggle and a "ask
  after this many episodes" picker.
- **Skip step.** Choose how far the skip buttons, a double-tap, and the remote fast-forward jump: 10, 15,
  or 30 seconds. While the controls are hidden, a left/right press on a remote now nudges the position and
  shows a small floating time, without raising the whole bar.
- **Now Playing card.** The lockscreen and quick-settings media controls now show the episode title, the
  show and season, and the poster art, and correctly handle live channels (no bogus progress bar or stuck
  spinner).
- **Default volume and an in-player volume slider.** Set the level a playback starts at, mute or unmute
  from the player, and use the right-half swipe to change the app's own volume.
- **Smarter resume.** Resuming now skips a barely-started or all-but-finished title, and the built-in
  player defers its resume jump to the first frame so a resume lands cleanly instead of on a blank frame.
- **Honest Dolby Vision.** The DOLBY VISION badge now shows only when a Dolby Vision source is actually
  playing in Dolby Vision on a capable screen; Playback Info tells you when a DV source is being tone-mapped
  to HDR10 instead of claiming Dolby Vision over tone-mapped video.

### Add-ons

**Install add-ons by QR, browse the community store, and configure or swap an add-on in place.** Managing
add-ons no longer means typing a long manifest URL on a remote. Install by QR shows a code on this device
that you scan with your phone: paste any add-on's manifest link on the page that opens and it installs here
and syncs to your account, so a keyboardless Android TV can add sources in seconds. Discover add-ons opens
a browsable store over the official community collection, each entry showing whether it is reachable right
now, with a one-tap install that goes through the same path as a pasted URL. Every installed add-on now
carries a Configure action (it opens the add-on's settings page in your browser on phone, or as a QR to
finish on your phone from TV) and a Change-URL action that swaps its manifest link in place, installing the
new one first so a bad link never leaves you with neither. Pasting an add-on's `/configure` page instead of
its personalized manifest now guides you to finish setup rather than silently installing a dead copy.
Android phone and TV.
### Details page

**A richer, safer title details page, matching the Apple app.** The details page gains the breadth the Apple
apps have: a spoiler-safe mode that blurs unwatched episode thumbnails and hides their descriptions behind a
tap-to-reveal (turn it on under Home and Discover, and revealing an episode never marks it watched); a
cross-provider ratings strip led by the IMDb star, then Rotten Tomatoes, Metacritic and TMDB, filled from
your own MDBList key when you have set one; for movies, a budget and box-office line (opt out under Home and
Discover), the theatrical and digital release dates for your region, and a franchise/collection rail listing
the whole series in release order. More Like This now blends the installed add-ons' genre-similar picks
behind TMDB's recommendations and starts filling in before the metadata finishes loading. Where to Watch
follows your region override before the device region and links out to the full JustWatch page. Titles your
add-ons cannot recognise are resolved automatically where possible, and when nothing can, you now get a clear
"Details unavailable" screen with a Try Again button instead of a page that never loads; a title with no
metadata still shows a hero and its source list. Cast now always shows as a rail (with initials when there is
no photo), a missing synopsis falls back to TMDB, and Share moves to a tidy overflow button in the top corner.
### Home and Discover

**Editorial Home rows, a richer Collections hub, and a browsable decade shelf.** Home now leads with a set
of hand-curated editorial rows (Critically Acclaimed, Hidden Gems, Modern Classics, Award Winners), built
from public catalogs so they fill in even when you have no extra add-ons installed, and each open shows a
freshly rotated slice rather than the same list every time. The Collections hub gains a Browse by Decade
shelf from the 2010s all the way back to the 1950s, each opening Movies, Shows, New, and Trending scoped to
that decade, and every Discover card, genre tile, and decade tile now shows a representative piece of
artwork instead of a flat gradient. Two genres that were missing, Fantasy and Mystery, are back. You can
turn on the editorial rows or the Collections hub under Settings > Home & Discover, and the hub now sits
wherever you place Collections in Customize Home (and disappears when you hide it there), on both phone and
TV.

**Browse another region, and a fleet safety switch.** A new Discover region control under Settings > Home &
Discover lets you point the Collections hub at another market's streaming services and catalogs, so you can
browse what is available elsewhere while Auto keeps following your device region. The Collections hub also
now honors a remote feature switch, so it can be turned off fleet-wide if its catalog service ever needs
maintenance, with no app update. Android phone and TV.

**Titles you plan to watch on SIMKL now surface their air and release dates.** The shows and movies on your
SIMKL plan-to-watch list are folded into the Upcoming Episodes and Upcoming Movies rows alongside your
library and local watchlist, so a followed title shows its next date whether or not it is in your library.
This drops back out the moment you disconnect SIMKL.

### Live TV

**A Live TV tab, matching the Apple app.** VortX Android now has a dedicated Live TV surface, on phone and
on Android TV, that gathers the channels from every Live TV add-on you have installed into rows of channel
tiles you can browse and play. Add a playlist under Settings > Live TV (an M3U / M3U8 URL or an Xtream
Codes login) and its channels show up here alongside any other live-TV, channel, or events add-on you
have. Selecting a channel opens the standard details page and plays the live stream through the existing
player, exactly like a movie or episode. Channels use the same account and add-on set as the rest of the
app, so a playlist added on Apple or the web appears here too. You can hide the tab under Settings > Tab
bar. There is no separate EPG or on-device playlist parsing: channels flow through the same catalog
pipeline as everything else.

### Accounts and sync

**Trakt and SIMKL watchlist now syncs both ways, and scrobbling respects your profile.** When you add or
remove a title from your library, VortX now mirrors that change to your connected Trakt and SIMKL
watchlists, so your want-to-watch list stays in step across every app and the website. This completes the
two-way link with the existing Trakt Watchlist and SIMKL Watchlist home rails (which already show what is
on your remote lists). A push that happens while you are offline is saved and retried automatically the
next time the app opens. Live scrobbling (start, pause, stop) and the watchlist mirror now only ever run
for your main profile: a guest or kids profile plays against its own local history and never writes into
your account's Trakt or SIMKL. Everything stays dormant until you connect Trakt or SIMKL, and no change is
ever written into data the official Stremio apps read. Android phone and TV.

### Playback and buffering

**Smoother 4K and HDR buffering, with the buffer sized to your device.** VortX now sizes the player's
forward buffer to how much memory your phone or TV box actually has, instead of one flat cap for every
device. On a device with plenty of RAM the buffer is allowed to grow, so a heavy 4K stream whose bitrate
spikes no longer drains a too-small buffer and stutters; on a smaller device the buffer stays tight so
playback keeps clear of the memory limit. The Dolby Vision and Atmos path (ExoPlayer) additionally gets a
deeper, RAM-sized read-ahead and starts each stream with a high bandwidth estimate, so the first few
seconds of a fast stream are not throttled by a cold, pessimistic guess. Torrent, loopback, and
reduced-performance playback stay on the conservative tight buffer as before. The tuning is on by default
and can be turned off with the `vortx.player.bufferTuning` settings key. Android phone and TV.
