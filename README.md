# ReplayCenter

ReplayCenter is a desktop-oriented live TV viewing application for EPGStation.

The first implementation target is a macOS app using SwiftVLC. The current
vertical slice can load a JSON config, display live streams as tiles, play audio
only from the focused tile, and switch dual-mono audio with `S` / `L` / `R`.

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

- `deinterlace`: `yadif`
- `networkCachingMs`: `1000`
- `audioOnlyFocusedTile`: `true`
