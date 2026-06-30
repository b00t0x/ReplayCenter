# ReplayCenter

ReplayCenter is a desktop-oriented live TV viewing application for EPGStation.

The first implementation target is a macOS app using SwiftVLC. Live streams are
fed through the bundled stream filter helper before reaching SwiftVLC, so the
same playback path is used for normal stereo, dual-mono, and multi-stream audio
programs. The current vertical slice can load a JSON config, display live
streams as tiles, play audio only from the focused tile, and switch dual-mono or
multi-stream audio between primary and secondary audio. It also contains the
first EPGStation API client layer for channel selection.

Current keyboard and mouse controls:

- Click a tile to focus it.
- Drag a tile onto another tile of the same size to swap them.
- Press `C` to choose a channel for the focused tile.
- Double-click a tile, or use its hover `選局` button, to choose a channel for
  that tile without moving focus first.
- Press `Delete` to clear the focused tile.
- Press `M` to mute or unmute the focused tile.
- Press `[` or `]` to change the focused tile volume in 5% steps.
- Use the focused tile's hover controls to switch audio, reload, mute, clear, or
  adjust volume.
- Use the focused tile's hover reload button to reconnect the live stream when
  the input clock suggests the stream has fallen behind.
- Use the macOS `再生` menu for the same commands exposed by the focused tile
  control panel.
- Use the macOS `表示` menu for global viewing commands: fixed window sizes
  based on physical pixels, full screen, and the input clock overlay toggle.

## Requirements

- macOS 15+
- Swift 6.3+
- Xcode command line tools

SwiftVLC requires Swift 6.3+. On development machines where the matching Xcode
cannot be installed, use the Swift.org macOS toolchain from
https://www.swift.org/install/macos/. In the current development environment,
`~/.swiftly/bin/swift` is the Swift 6.3 toolchain while `/usr/bin/swift` may
still point at Xcode's older Swift.

## Run

```bash
swift build --product ReplayCenterStreamFilter
swift run ReplayCenter
```

## Build App Bundle

Use the bundled script to create a local `.app` bundle. The default architecture
is `x86_64` so local packaging checks stay reasonably fast on the current
development machine.

```bash
scripts/build-app.sh
```

The app is written to `.build/app/ReplayCenter.app` by default. The stream
filter helper is copied into `Contents/MacOS` next to the main executable, which
matches ReplayCenter's default helper discovery path.

To build a universal local bundle, build each architecture separately and merge
the executables with `lipo`:

```bash
scripts/build-app.sh --arch universal
```

SwiftPM's one-shot universal build is intentionally avoided because the current
SwiftVLC/libVLC static library can trip the Apple linker when linked with
`--arch arm64 --arch x86_64` in a single invocation. Per-architecture builds
followed by `lipo` have been more reliable.

The script ad-hoc signs the bundle by default. Use `--no-sign` when inspecting
unsigned build output.

```bash
scripts/build-app.sh --arch x86_64 --no-sign
scripts/build-app.sh --arch universal --output .build/app/ReplayCenter-universal.app
```

App icons can be provided as either a traditional `.icns` file or an Icon
Composer `.icon` document. The final repository location for icon sources is
still undecided; for now the script automatically uses `Resources/AppIcon.icns`
or `Resources/AppIcon.icon` when present. To pass an icon explicitly:

```bash
scripts/build-app.sh --icon Resources/AppIcon.icon
```

When a `.icon` document is used, the script compiles it with Xcode's `actool`.
This writes both `Assets.car` for modern Icon Composer appearances and a
fallback `AppIcon.icns`. With `CFBundleIconName` present, macOS can use the
asset catalog icon on Sequoia as well; the `.icns` is kept for tools or
contexts that still look at the legacy icon file. This path requires Xcode or
another toolchain that provides `actool`.

To re-test macOS local network permission prompts, build with a temporary bundle
identifier and run that app:

```bash
scripts/build-app.sh --bundle-id org.b00t0x.ReplayCenter.LocalNetworkTest
```

ReplayCenter is not notarized at this stage. If macOS blocks a downloaded build,
remove quarantine from the installed app:

```bash
xattr -dr com.apple.quarantine /Applications/ReplayCenter.app
```

During local development, reset ReplayCenter's privacy approvals with:

```bash
tccutil reset All org.b00t0x.ReplayCenter
```

On the current development environment, `tccutil reset LocalNetwork ...` does
not reset the local network approval entry, so use `All` or a temporary bundle
identifier for first-run permission testing.

## Config

ReplayCenter can start without a JSON config. Configure the EPGStation URL from
the in-app settings screen; runtime settings are saved in the user's Application
Support directory.

`--config` and `REPLAYCENTER_CONFIG` remain as explicit debug inputs. When one
is provided, the JSON config for that launch is used instead of saved runtime
settings. `config.local.json` is no longer loaded implicitly. Real EPGStation
hosts, channel IDs, tokens, and other private values should stay out of
committed files.

`config.example.json` is a representative debug config rather than a minimal
normal-use config. For normal app use, set the EPGStation URL from the settings
screen and let ReplayCenter manage runtime state. Use JSON config when you want
to launch with fixed debug inputs and ignore saved runtime settings for that
launch.

Representative debug config keys:

- `epgStationBaseURL`: EPGStation host URL used by channel selection.
- `streams`: fixed startup streams for direct URL playback tests. Leave empty
  for normal EPGStation channel selection.
- `tileLayout`: optional fixed tile grid for a debug launch, for example
  `{ "columns": 3, "rows": 2 }`, or explicit `placements` for non-uniform
  layouts.
- `liveStreamContainer`, `largeTilePlayback`, and `smallTilePlayback`: playback
  defaults used before runtime settings are saved.
- `streams[].deinterlace`: per-stream deinterlace mode for fixed URL playback
  tests.
- `networkCachingMs`, `vlcArguments`, and `mediaOptions`: low-level playback
  experiments.
- `volumePercent` and `keepFocusOnSingleLargeTile`: startup behavior overrides
  for reproducible debug launches.
- `streams[].audioMode`: initial audio selection override for fixed debug
  streams. Use `left` for primary audio or `right` for secondary audio.
- `streamFilter.filterPath`: custom helper executable path. Usually this can
  stay unset because ReplayCenter looks for `ReplayCenterStreamFilter` next to
  the app binary or in `.build/debug` / `.build/release`. The
  `REPLAYCENTER_STREAM_FILTER_PATH` environment variable can also override it.

For EPGStation channel selection, playback profiles are applied by tile size.
Mode names are loaded from EPGStation's `/api/config` `streamConfig` response.
When `isUnconverted` is `true`, ReplayCenter treats the stream as
raw/interlaced input and applies the selected deinterlace mode. Otherwise it
treats the stream as transcoded/progressive input and forces deinterlace off.
Already selected EPGStation channels are restarted only when the effective
playback pipeline changes. Fixed URL streams from config remain URL-driven.

ReplayCenter reads the EPGStation live TS stream inside the app and writes it
to the helper stdin directly.

Initial local validation of the filter-only playback path:

- Primary/secondary switching works for dual-mono programs.
- Ordinary stereo programs also play without immediately visible AV drift.
- 9 simultaneous streams appear stable in the current development environment.
- All filter helper processes together stayed within roughly 1% CPU usage.
- App CPU usage stayed around the previous SwiftVLC baseline.
- Stopping playback or clearing tiles also removed the corresponding helper
  processes, so no lingering helpers were observed.

Runtime state, such as the last tile layout, is saved outside the config file in
the user's Application Support directory. Set `REPLAYCENTER_STATE_PATH` during
development to override the state file location.

`tileLayout` also accepts explicit cell placements for non-uniform layouts. Each
placement is expressed in 16:9 logical cells, and all cells must be covered
without overlap:

```json
{
  "columns": 3,
  "rows": 3,
  "label": "3x3 large top-left",
  "placements": [
    { "x": 0, "y": 0, "width": 2, "height": 2 },
    { "x": 2, "y": 0, "width": 1, "height": 1 },
    { "x": 2, "y": 1, "width": 1, "height": 1 },
    { "x": 0, "y": 2, "width": 1, "height": 1 },
    { "x": 1, "y": 2, "width": 1, "height": 1 },
    { "x": 2, "y": 2, "width": 1, "height": 1 }
  ]
}
```

## Development Notes

ReplayCenter is still in a vertical-slice phase. The current goal is to keep the
core playback path observable and easy to adjust before polishing the final
operation model or public documentation.

Playback flow:

```text
EPGStation live stream
  -> app-internal HTTP stream reader
  -> ReplayCenterStreamFilter
  -> SwiftVLC Media(fileDescriptor:)
  -> focused-tile audio / tiled video
```

The app intentionally routes every tile through `ReplayCenterStreamFilter`. The
filter has been light enough in local validation, and using one playback path
avoids reconnecting streams when a program changes between stereo and dual-mono
audio.

The filter also detects multiple AAC audio streams. For multi-stream programs it
rewrites PMT output and drops non-selected audio packets so SwiftVLC sees only
the selected audio stream. This keeps dual-mono and multi-stream switching on
the same primary/secondary UI path.

The filter also observes TDT/TOT clock tables when they are present in the TS
and emits clock status lines to ReplayCenter. The tile hover overlay can show
the difference between that input stream clock and the current Mac clock.
This is an input-side clock check, not a measurement of VLC's internal playback
buffer. Transcoded streams or backend configurations that drop TDT/TOT will
show the clock as unavailable.

Tile playback state is intentionally minimal:

- `idle`: no stream assigned
- `starting`: stream launch is in progress, often too brief to see on screen
- `playing`: normal state, no visible badge
- `failed`: visible `再生失敗` badge on the tile, with details in stderr

The pipeline logs stream and helper exits with the tile label. If playback
fails, check the terminal output for `stream input ended`,
`stream filter exited`, or
`playback failed`.

The focused tile controls currently show audio stream detection state for
development validation. Treat this as temporary diagnostics. In a polished UI,
stream details should move to a separate optional display such as a "show stream
information" setting, rather than living in the main operation controls.

Current development TODOs:

- Decide the final tile operation UI before polishing shortcuts and overlays.
- Keep the on-tile state display quiet during normal playback; show only
  actionable failures unless debugging needs more detail.
