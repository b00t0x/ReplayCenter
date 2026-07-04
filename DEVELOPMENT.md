# ReplayCenter 開発メモ

この文書は ReplayCenter の開発、ビルド、デバッグ、リリース手順のためのメモです。
利用者向けの概要と使い方は [README.md](README.md) を参照してください。

## 要件

- macOS 15+
- Swift 6.3+
- Xcode command line tools
- Icon Composer `.icon` を扱う場合は `actool` を含む Xcode

SwiftVLC は Swift 6.3+ を要求します。
開発環境で対応する Xcode を入れられない場合は、Swift.org の macOS toolchain を使います。
現在の開発環境では `~/.swiftly/bin/swift` が Swift 6.3 系で、`/usr/bin/swift` は
Xcode 側の古い Swift を指す可能性があります。

## 実行

```bash
swift build --product ReplayCenterStreamFilter
swift run ReplayCenter
```

debug build は再生と stream filter の詳細ログを stderr に出します。
release build は通常ログを抑制し、エラーと、アプリ内部で読む `[filter-status]` を維持します。

## アプリバンドル作成

ローカル確認用の `.app` bundle は次で作成します。
既定の architecture は、開発機での確認を速くするため `x86_64` です。

```bash
scripts/build-app.sh
```

既定の出力先は `.build/app/ReplayCenter.app` です。
`.app` 名にはバージョンを含めません。
stream filter helper は main executable と同じ `Contents/MacOS` にコピーされます。

アプリのバージョンは `VERSION` で一元管理します。
`scripts/build-app.sh` はこの値を `CFBundleShortVersionString` と `CFBundleVersion` に使います。

Universal bundle を作る場合:

```bash
scripts/build-app.sh --arch universal
```

SwiftPM の一発 universal build は避けています。
現在の SwiftVLC/libVLC static library は、単一 invocation で
`--arch arm64 --arch x86_64` を指定すると Apple linker で問題が出ることがあります。
そのため architecture 別に build し、`lipo` で結合します。

署名と検証:

```bash
scripts/build-app.sh --arch x86_64 --no-sign
scripts/build-app.sh --arch universal --output .build/app/ReplayCenter.app

scripts/verify-app.sh --arch x86_64 .build/app/ReplayCenter.app
scripts/verify-app.sh --arch universal .build/app/ReplayCenter.app
```

`scripts/build-app.sh` は既定で ad-hoc signing と bundle verification を行います。

## アプリアイコン

アプリアイコンは `Resources/AppIcon.icon` を既定入力とします。
`.icns` を渡すこともできます。

```bash
scripts/build-app.sh --icon Resources/AppIcon.icon
```

`.icon` document を使う場合、script は Xcode の `actool` で compile します。
出力には modern appearance 用の `Assets.car` と fallback の `AppIcon.icns` が含まれます。
`CFBundleIconName` がある場合、Sequoia でも asset catalog 側の AppIcon が使われる可能性が高く、
`.icns` は legacy context 向けの保険として扱います。

## dmg 作成

`ReplayCenter.app` と `/Applications` alias を含む drag-and-drop dmg を作ります。

```bash
scripts/build-dmg.sh --arch universal
```

`.app` 名は `ReplayCenter.app` のままにします。
dmg filename には version と architecture を含めます。

例:

```text
.build/dist/ReplayCenter-1.0.0-universal.dmg
```

dmg は `UDZO` 形式で圧縮します。
作成時の volume size は staging folder の `du` 結果から余裕を持って計算します。

## GitHub Actions

`.github/workflows/build-dmg.yml` が dmg を作成します。
`main` push ごとには実行しません。

- `workflow_dispatch`: dmg を build し、Actions artifact として upload
- `v*` tag push: release dmg を build し、tag version と `VERSION` の一致を確認し、
  draft GitHub Release を作成

Release notes は `CHANGELOG.md` から読みます。
たとえば `v1.0.0` では `## 1.0.0` section が GitHub Release body になります。
section がない場合は fallback body を生成します。

## ローカルネットワーク許可の検証

macOS の local network permission prompt を再検証したい場合は、
一時的な bundle identifier で build して実行します。

```bash
scripts/build-app.sh --bundle-id org.b00t0x.ReplayCenter.LocalNetworkTest
```

通常の privacy approval を reset する場合:

```bash
tccutil reset All org.b00t0x.ReplayCenter
```

現在の開発環境では `tccutil reset LocalNetwork ...` だけでは local network approval entry が
初期状態に戻らないことがあるため、`All` または一時 bundle identifier を使います。

## デバッグ設定

ReplayCenter は JSON config なしで起動できます。
通常利用ではアプリ内設定画面から EPGStation URL を保存し、runtime settings は
Application Support 配下に保存します。

`--config` と `REPLAYCENTER_CONFIG` は明示的な debug input として残しています。
指定した場合、その launch では保存済み runtime settings の代わりに JSON config を使います。
`config.local.json` は暗黙には読みません。

`config.example.json` は通常利用の最小設定ではなく、代表的な debug config 例です。
実 EPGStation host、channel ID、token、その他 private value は commit しないでください。

代表的な debug config keys:

- `epgStationBaseURL`: channel selection 用の EPGStation URL
- `streams`: direct URL playback test 用の固定 startup streams
- `tileLayout`: debug launch 用の固定 tile grid
- `liveStreamContainer`, `largeTilePlayback`, `smallTilePlayback`: runtime settings 保存前の playback defaults
- `streams[].deinterlace`: fixed URL playback test 用の per-stream deinterlace
- `networkCachingMs`, `vlcArguments`, `mediaOptions`: low-level playback experiments
- `volumePercent`, `keepFocusOnSingleLargeTile`: reproducible debug launch 用 startup behavior
- `streams[].audioMode`: fixed debug stream の initial audio selection override
- `streamFilter.filterPath`: custom helper executable path

`REPLAYCENTER_STREAM_FILTER_PATH` でも helper executable path を override できます。
通常は `ReplayCenterStreamFilter` が app binary の隣、または `.build/debug` / `.build/release` に
あれば自動検出されます。

Runtime state file の場所を変える場合:

```bash
REPLAYCENTER_STATE_PATH=/tmp/replaycenter-state.json swift run ReplayCenter
```

### Runtime state version

`app-state.json` は top-level `version` を持ちます。
現在の runtime state schema version は `1` です。

- `version` が無い state file は pre-versioned format として `0` 扱いで読み込みます。
- 読み込めた state はアプリ内では現行 version として扱い、次回保存時に
  `version: 1` を書き出します。
- `app-state.json` に非互換な format change を入れる場合は
  `AppState.currentVersion` をインクリメントし、この節に migration 方針を追記します。
- アプリが知らない future version は読み込まず、state load failure として扱います。

## EPGStation 再生プロファイル

EPGStation channel selection では、再生 profile は tile size ごとに適用します。
mode 名は EPGStation `/api/config` の `streamConfig` response から取得します。

- `isUnconverted == true`: raw/interlaced input とみなし、選択した deinterlace mode を適用
- `isUnconverted == false`: transcoded/progressive input とみなし、deinterlace を off にする

選局済み channel は、effective playback pipeline が変わる場合だけ restart します。
config の fixed URL stream は URL-driven のままです。

## タイル配置のデバッグ形式

`tileLayout` は explicit cell placements を受け付けます。
Placement は 16:9 logical cell で表現し、全 cell を overlap なしで覆う必要があります。

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

## 再生パイプライン

```text
EPGStation live stream
  -> アプリ内 HTTP stream reader
  -> ReplayCenterStreamFilter
  -> SwiftVLC Media(fileDescriptor:)
  -> フォーカスタイル音声 / タイル映像
```

全 tile は `ReplayCenterStreamFilter` を通します。
filter は軽量で、通常ステレオ、デュアルモノラル、2 ストリーム音声を同じ playback path で扱えます。

2 ストリーム音声では PMT を rewrite し、非選択 audio packet を落として、
SwiftVLC には選択した audio stream だけが見えるようにします。
デュアルモノラルと 2 ストリーム音声は同じ主/副 UI で切り替えます。

filter は TS 内の TDT/TOT clock table を観測し、clock status line を ReplayCenter へ出します。
tile hover overlay の clock 表示は input stream clock と Mac の現在時刻の差分であり、
VLC 内部 buffer の測定ではありません。
transcoded stream や backend configuration によって TDT/TOT が落ちる場合は clock unavailable になります。

## ローカル検証メモ

- デュアルモノラル番組で主/副切り替えが動作することを確認済み。
- 通常ステレオ番組でも、目立つ AV drift なしに再生できることを確認済み。
- 開発環境では 9 ストリーム同時再生がおおむね安定していた。
- filter helper process 全体の CPU 使用率はおおむね 1% 以内に収まっていた。
- アプリ本体の CPU 使用率は、SwiftVLC 直接再生時のベースラインに近い範囲だった。
- 再生停止やタイルクリア時に、対応する helper process が終了することを確認済み。
