# VortX Android Changelog

Notable Android changes, newest first. VortX Android is in active development on the shared engine. The
Apple release notes live in the repository [CHANGELOG.md](../CHANGELOG.md).

## Unreleased

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
