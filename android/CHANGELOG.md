# VortX Android Changelog

Notable Android changes, newest first. VortX Android is in active development on the shared engine. The
Apple release notes live in the repository [CHANGELOG.md](../CHANGELOG.md).

## Unreleased

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
