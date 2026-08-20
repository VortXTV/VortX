# VortX Android Changelog

Notable Android changes, newest first. VortX Android is in active development on the shared engine. The
Apple release notes live in the repository [CHANGELOG.md](../CHANGELOG.md).

## Unreleased

### Player

**Sound that follows your speakers.** The player now reads the audio route you are actually listening on
(phone speaker, wired or Bluetooth headphones, an HDMI receiver, a USB DAC, or a cast target) before it
decides how to send sound. A surround (5.1 or Atmos) track is kept intact for a receiver that can play it
and cleanly folded down to stereo for anything that cannot, so a multichannel movie can never come out
silent on a stereo output. Dolby/DTS passthrough is only handed to a route that can decode it. The Audio
Output control (Auto, Stereo, Surround, Passthrough) stays on the same setting key as the Apple app.

**Picks the right audio track for your setup.** When a title carries more than one audio track in your
preferred language (say an English 5.1 and an English stereo), the player now chooses by what you are
listening on: a receiver that can play surround gets the full 5.1 or 7.1 mix, while headphones or a phone
speaker get the native stereo track instead of a folded-down surround one. Your preferred audio language
still comes first; this only breaks the tie between same-language tracks, and titles that report no channel
information behave exactly as before.

**Chinese, Japanese, Korean, and other non-Latin subtitles render properly.** The libmpv engine now draws
subtitle glyphs from a CJK-capable fallback font set, so Chinese, Japanese, Korean, Arabic, Hebrew, Thai, and
similar scripts show real characters instead of empty boxes, the same way the Apple app does. It only fills in
glyphs the chosen style cannot draw, so your Latin subtitles keep their look.

**Community subtitle groundwork.** The foundation for VortX's community subtitle pool landed: a signed,
fail-soft client that can read subtitles other viewers have contributed for the same title, learn a per-release
sync offset and apply it automatically, and contribute embedded or add-on subtitle text back so the next viewer
benefits. Your own manual sync nudge always wins and teaches the pool the right offset for that exact release. A
later update wires this into the subtitle picker; today it ships as the tested groundwork behind it.

**A scrubber that finally looks like the Apple app.** The progress bar now honours your Seek Bar Style
choice (fourteen looks, from Classic and Minimal to Wave, Ripple, Comet, Liquid, and Spectrum), animating
from a continuous clock so a wave really travels. It draws a faint grey buffered-ahead band so you can see
how far the stream has loaded, thin ticks at chapter boundaries, and coloured bands over skippable intros,
recaps, and credits. The style is on the same setting key as Apple and web, so a look you pick on one device
shows up on the others. Reachable in the player under Player Settings, Seek Bar Style.

**Jump by chapter.** A title with chapters now shows Previous and Next chapter buttons in the transport
row; Previous restarts the current chapter when you are a few seconds in, then steps back, and each button
dims when there is no boundary that way. Titles without chapters look exactly as before.

**Aspect ratio is remembered.** Your Fit, Fill, or Stretch choice now persists across titles and devices on
the same key the Apple app uses, instead of snapping back to Fit every time you start something.

**HDR tone mapping control.** Player Settings gains an HDR Tone Mapping choice (Auto, On, Off) on the same
key as the Apple app. Auto tone-maps HDR and Dolby Vision down to SDR only when the screen cannot show HDR,
On always tone-maps (the fix for a green or purple Dolby Vision mis-render), and Off always asks for HDR.
It appears on the libmpv engine, which tone-maps in software; the Dolby Vision player leaves HDR to the panel.

**Playback Info shows performance.** The Playback Info sheet now reports dropped frames and how many seconds
of buffer sit ahead of the playhead, on both engines, so a struggling device or a starving link is obvious.

**Chapters on the Dolby Vision player too.** The Dolby Vision (ExoPlayer) engine now surfaces in-stream ID3
chapters, so the chapter picker and chapter ticks work there for streams that carry them, not only on libmpv.

**Share and open elsewhere.** A share button in the player lets you share the current stream's link or hand
it off to another installed video player, through the normal Android chooser so any app is offered and your
"always" choice is remembered. It appears only for a real remote stream, never a loopback torrent or a trailer.

**Keep playing in the background.** Player Settings gains a Keep playing in background toggle (on the same key
and default as the Apple app), so audio keeps going with the screen off or the app behind another instead of
pausing. The libmpv engine drops the off-screen video to save power. Turn it off to pause on background.

**Skip from the Picture-in-Picture window.** The PiP window now shows skip-back and skip-forward controls
either side of play/pause, seeking by your Skip step, so you can move through a video without leaving PiP.

**Contribute skip times.** Player Settings now has a Contribute a skip time editor: pick a segment (intro,
recap, credits, or preview), set its start and end from the playhead, and submit. It posts to the same
skip.vortx.tv worker plus the community and any custom database, exactly like the Apple app, and appears only
for a title with an IMDb id that is not live.

**Your own scrub previews, even before the pool has them.** A per-device trickplay cache now serves scrub
thumbnails from your own captured frames when the shared community pool has none yet (the first person to
watch a title, or offline). It survives restarts on disk, prunes old frames, and is capped so it never grows
without limit. This closes the second trickplay layer the Apple app has.

**Auto-rotate to landscape.** On a phone, opening a video now turns the screen to landscape to match it and
restores your orientation when you leave, on the same key and default as the Apple app. Trailers and TV are
unaffected, and you can turn it off in Player Settings.

**Anime4K upscaling.** The Anime4K neural upscaling preset now works on the libmpv engine: the bundled shader
chain is extracted and applied through mpv, so animation gets the same anime-tuned upscaling the Apple app
offers. It is a heavy GPU option best used on animation, and it appears only on builds that carry libmpv (it
falls back gracefully if the shaders cannot be armed).

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

**The couch detail page gains the franchise rail and box-office line.** A movie's title page on the TV now
shows the collection it belongs to as its own poster rail, just above More Like This, in release order, so a
franchise is one click to browse end to end. It also shows a compact budget, box office, and profit line under
the ratings, on the same "Show budget & box office" setting the phone and Apple read, so turning it off on any
device turns it off everywhere.

**A quiet "You're offline" chip.** When the TV loses its internet connection, a small chip appears at the
bottom of the screen letting you know, and pointing out that your downloads still play. It clears itself the
moment the connection is back and never steals focus, so the remote keeps driving the content beneath it. A
brief Wi-Fi blip no longer flickers it in and out.

**Re-select to jump back to the top.** Selecting the Home or Discover rail entry again while you are already on
it now scrolls that surface back to the top, so a long scroll down is one click to reset. Switching between
tabs still keeps each one where you left it.

**Pick and reorder your streaming services.** A new Streaming Services screen under Settings > Appearance lets
you choose exactly which services show in the Collections hub and put them in the order you want, with Up,
Down, Remove, and an Add list of everything available in your region. Leave it untouched and the hub keeps
showing every service in your region as before. Your picks ride the same setting the Apple app uses, so they
carry across your devices.

**An Upcoming screen for what is coming soon.** Settings > Library now has an Upcoming screen that gathers the
next-airing episode of every series you follow and every followed movie with a release on the way into one
full-screen grid, the couch version of the Apple app's Upcoming view. It reuses the same "Coming soon" rows
Home already builds, so nothing new is fetched to show it, and each poster opens straight into the title.

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

### Posters, artwork and ratings

**Ratings baked onto your posters, on by default.** Every catalog and detail poster now routes through
VortX's own keyless poster service, so the cross-provider rating (IMDb, Rotten Tomatoes, Metacritic, TMDB)
is baked right onto the artwork with no key and no setup. Where a poster is not baked (a card showing clean
art, or an add-on id the service cannot render), a small rating badge is drawn over the card instead, so a
rating shows either way. The original artwork is always carried as a fail-soft fallback, so a title the
service cannot map keeps its own poster.

**Poster Style screen.** A new Settings > Poster Style screen sets the card width, corner radius, a landscape
16:9 vs portrait layout, and a hide-labels option, with a live preview that updates as you change each one.
The same screen carries the artwork toggles: turn ratings-on-posters off, switch on ERDB baked posters,
backdrops and logos, or use fanart.tv community logos for the hero.

**Richer hero art.** The detail hero now tints its band with the dominant color of the backdrop, and can
show a fanart.tv or rating-baked clearlogo in place of the title text. Streaming-service tiles in Discover
render each service's real brand logo on its own brand color, instead of a generic mark.

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

**Hide the sections you never browse.** Settings > Home & Discover now has a Collections categories block that
turns whole hub rows off: Discover cards, Streaming services, Genres, or Decades. The Home and Discover hubs
honour it live on phone and TV, and it rides the same setting the Apple app uses, so a section you hide on one
device stays hidden on the others.

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

**Your app settings now follow you across devices.** When you are signed in, VortX carries your global
settings on the same private, encrypted account channel and under the same setting keys the Apple app and the
website use, so a choice made on one device shows up on the others. This covers the appearance and text size,
subtitle look, audio output, the player behaviour toggles, the Home and Discover layout, the hidden tabs, the
language override, and the Stremio mirror switches. Device-specific choices are deliberately left out and stay
per device, exactly as the Apple app leaves them out: the streaming cache size, the custom streaming server,
video upscaling, the Dolby Vision toggle, and the download queue and limits. Your per profile preferences keep
travelling with the profile, and your account sign-in never leaves this device. Android phone and TV.

**Your debrid keys now follow your account across devices.** A debrid service key (Real-Debrid, AllDebrid,
Premiumize, or TorBox) entered on one device now travels on the same private, encrypted account channel and
appears on your other signed-in devices, so you set it once. VortX only ever adds the keys this device holds
and never removes one another device or the website set, so connecting a service on your phone does not clear
the one on your TV. The keys stay tied to the signed-in account and are never written into anything the
official Stremio apps read. Android phone and TV.

**Auto-added Library state now lines up with the other apps.** The record of which titles VortX auto-added to
your Library at about a minute of playback (so a title you later remove by hand is not re-added) is now stored
under the exact same key the Apple app and the website use, instead of a slightly different Android-only one.
Anything already remembered on this device is carried across to the shared key, so nothing is lost. Android
phone and TV.

### Privacy

**Anonymized signals that sharpen your recommendations, on by default and fully opt-out.** With the same
anonymized-data preference the Apple app uses (on by default), VortX can now contribute a small, anonymous
"this was watched" signal that helps the app surface better Trending and Popular results over time. It carries
no account, no name, and nothing that identifies you or your device, is limited to at most one signal per
title per day, and simply does nothing if you turn the preference off. The preference is the single switch for
this kind of anonymized contribution, held on the same key as the Apple app and the website so a choice you
make on one carries to the others. Android phone and TV.

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
