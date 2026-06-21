# ReplayCenter

ReplayCenter is a desktop-oriented live TV viewing application for EPGStation.

The first implementation target is a macOS app using SwiftVLC. The current
vertical slice can load a JSON config, display live streams as tiles, play audio
only from the focused tile, and switch dual-mono audio with `S` / `L` / `R`.
It also contains the first EPGStation API client layer for channel selection.

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
- `deinterlace`: `yadif`
- `networkCachingMs`: `1000`
- `audioOnlyFocusedTile`: `true`
