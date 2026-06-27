# ReplayCenter

ReplayCenter is a desktop-oriented live TV viewing application for EPGStation.

The first implementation target is a macOS app using SwiftVLC. Live streams are
fed through the bundled TS dual-mono filter helper before reaching SwiftVLC, so
the same playback path is used for normal stereo and dual-mono programs. The
current vertical slice can load a JSON config, display live streams as tiles,
play audio only from the focused tile, and switch dual-mono audio with
`S` / `L` / `R`. It also contains the first EPGStation API client layer for
channel selection.

Current provisional keyboard and mouse controls for development:

- Click a tile to focus it.
- Press `C` or double-click a tile to choose a channel for the focused tile.
- Press `Delete` or `Forward Delete` to clear the focused tile.
- Press `+` / `=` or `-` to grow or shrink the tile layout.
- Press `S`, `L`, or `R` to switch the focused tile's stereo mode.

## Requirements

- macOS 15+
- Swift 6.3+
- Xcode command line tools

## Run

```bash
cp config.example.json config.local.json
vi config.local.json
swift build --product ReplayCenterDualMonoFilter
swift run ReplayCenter --config config.local.json
```

## Config

`config.example.json` contains the public shape of the local config. Real
EPGStation hosts, channel IDs, tokens, and other private values should stay in
ignored `config.local.json` files.

Important defaults:

- `epgStationBaseURL`: EPGStation host URL used by the channel selection layer
- `liveStreamContainer`: `m2ts` or `m2tsll`
- `liveStreamMode`: EPGStation live stream mode, with `0` commonly used for unconverted `m2ts`
- `tileLayout`: fixed tile grid, for example `{ "columns": 3, "rows": 2 }`
- `startupStreams`: `configured` starts streams from config, `empty` starts with unassigned tiles
- `deinterlace`: `yadif`
- `networkCachingMs`: `1000`
- `audioOnlyFocusedTile`: `true`
- `dualMonoFilter`: helper process settings. `muxSelectedToStereo` defaults to
  `false`, which is the current stable setting from the PoC validation.

`filterPath` can usually stay unset. During development ReplayCenter looks for a
`ReplayCenterDualMonoFilter` executable next to the app binary or in
`.build/debug` / `.build/release`. Set `REPLAYCENTER_TS_FILTER_PATH` or
`dualMonoFilter.filterPath` when using a custom helper path.

The current implementation uses `/usr/bin/curl` to read the EPGStation live TS
stream and pipe it into the helper. This is a development bridge; the intended
longer-term implementation is to read the stream inside ReplayCenter and write
to the helper stdin directly.

Initial local validation of the filter-only playback path:

- `S` / `L` / `R` switching works.
- Ordinary stereo programs also play without immediately visible AV drift.
- 9 simultaneous streams appear stable in the current development environment.
- All filter helper processes together stayed within roughly 1% CPU usage.
- App CPU usage stayed around the previous SwiftVLC baseline.
- Stopping playback or clearing tiles also removed the corresponding helper
  processes, so no lingering helpers were observed.

Runtime state, such as the last tile layout, is saved outside the config file in
the user's Application Support directory. Set `REPLAYCENTER_STATE_PATH` during
development to override the state file location.

## Development Notes

ReplayCenter is still in a vertical-slice phase. The current goal is to keep the
core playback path observable and easy to adjust before polishing the final
operation model or public documentation.

Playback flow:

```text
EPGStation live stream
  -> /usr/bin/curl
  -> ReplayCenterDualMonoFilter
  -> SwiftVLC Media(fileDescriptor:)
  -> focused-tile audio / tiled video
```

The app intentionally routes every tile through `ReplayCenterDualMonoFilter`.
The filter has been light enough in local validation, and using one playback
path avoids reconnecting streams when a program changes between stereo and
dual-mono audio.

Tile playback state is intentionally minimal:

- `idle`: no stream assigned
- `starting`: stream launch is in progress, often too brief to see on screen
- `playing`: normal state, no visible badge
- `failed`: visible `再生失敗` badge on the tile, with details in stderr

The pipeline logs helper exits with the tile label. If playback fails, check the
terminal output for `curl exited`, `dual mono filter exited`, or
`playback failed`.

Current development TODOs:

- Replace the `/usr/bin/curl` bridge with app-internal stream reading.
- Decide the final tile operation UI before polishing shortcuts and overlays.
- Keep the on-tile state display quiet during normal playback; show only
  actionable failures unless debugging needs more detail.
