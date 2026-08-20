# VortX Android Changelog

Notable Android changes, newest first. VortX Android is in active development on the shared engine. The
Apple release notes live in the repository [CHANGELOG.md](../CHANGELOG.md).

## Unreleased

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
