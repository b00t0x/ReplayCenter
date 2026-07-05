# ReplayCenter Public Repo Guide

このファイルは ReplayCenter の実アプリケーションコード側リポジトリにおける
Codex 向け開発ルールである。

## 位置づけ

- このリポジトリには、公開用のアプリケーションコードと公開可能な仕様だけを置く。
- 非公開の作業メモ、AI 開発文脈、LAN 固有の詳細、調査用 clone、ローカルログは置かない。
- 親ディレクトリに `docs/` が存在する場合は、実装前に親側の要件・意思決定文書も確認する。

## ターゲット

- 実行環境は macOS 15+ とする。
- リリースビルドは `x86_64` / `arm64` の universal app を作る。
- 主な開発環境は macOS Sequoia。Tahoe 以降でも hit testing やタイトルバー挙動を確認する。
- バックエンドは EPGStation を主とする。Mirakurun は必要な補助情報がある場合だけ検討する。
- UI 言語は日本語を主とする。
- アプリのバージョンは `VERSION` で一元管理する。現在の次期リリース候補は `1.0.0`。

## ビルド環境

- SwiftVLC が Swift 6.3+ を要求するため、Swift Package の tools version は 6.3 とする。
- 現開発環境の macOS Sequoia には Swift 6.3 同梱 Xcode をインストールできないため、
  Xcode は現状維持し、Swift 6.3 は https://www.swift.org/install/macos/ から導入した
  Swift.org ツールチェインを使う。
- 通常の `/usr/bin/swift` は Xcode 側の Swift を指す可能性がある。ビルド確認では
  `~/.swiftly/bin/swift` など Swift.org ツールチェインの `swift` を優先して使う。

## 開発方針

- 実装は小さな検証サイクルで進める。
- 再生、選局、設定、複数タイル、配布手順は実装済みであり、現在は v1.0.0 リリース前の
  整理と検証を優先する。
- 実再生でしか検証できない部分が多いため、テストはデグレ防止と開発速度維持を目的に絞る。
- 再生ライブラリは SwiftVLC を採用済み。stream 前処理は同梱の
  `ReplayCenterStreamFilter` で扱う。
- `app-state.json` の永続フォーマットに非互換変更を入れる場合は、
  `AppState.currentVersion` をインクリメントし、必要な migration 方針を
  `DEVELOPMENT.md` に残す。

## 公開前提の注意

- 認証情報、トークン、秘密鍵、個人情報をコミットしない。
- ローカルホスト名、LAN 固有 URL、個別環境の設定値はサンプル化する。
- ビルド成果物、依存キャッシュ、ログ、録画データ、スクリーンショットの不要物はコミットしない。

## UI/UX

- PC 利用を前提に、マウス操作と右クリックを活用してよい。
- ホーム画面ではなく再生画面を中心にする。
- 固定ツールバーを常時表示せず、必要な操作はマウスオーバーやコンテキスト操作で出す方針を優先する。
- デザインは OS 標準アプリ程度の落ち着いた実用性を目指す。

## Git

- 通常の小変更、UI 調整、ドキュメント修正、軽いバグ修正は main 直コミットでよい。
- 大きめの機能改修、設計が揺れそうな作業、途中で壊れた状態が続きそうな作業は
  feature branch を使う。
- main は「常にリリース可能に近い作業線」として扱い、壊れたまま長く寝かせない。
- GitHub Actions は `workflow_dispatch` による dmg artifact 生成と、
  `v*` tag push による draft GitHub Release 作成に使う。
- Release note は `CHANGELOG.md` の該当 version section から生成する。
