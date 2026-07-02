#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-dmg.sh [options]

Build ReplayCenter.app and package it into a drag-and-drop DMG.

Options:
  --arch ARCH       Build architecture: x86_64, arm64, or universal.
                    Defaults to x86_64 for fast local packaging checks.
  --configuration  SwiftPM configuration: release or debug. Defaults to release.
  --output PATH    Output .dmg path. Defaults to
                   .build/dist/ReplayCenter-<version>-<arch>.dmg.
  --bundle-id ID   CFBundleIdentifier. Passed to build-app.sh.
  --icon PATH      App icon source. Passed to build-app.sh.
  --no-sign        Skip ad-hoc codesigning.
  -h, --help       Show this help.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$repo_root/VERSION"

if [[ ! -f "$version_file" ]]; then
  echo "VERSION file not found: $version_file" >&2
  exit 1
fi

app_version="$(tr -d '[:space:]' < "$version_file")"
if [[ ! "$app_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "VERSION must be numeric with up to three dot-separated components: $app_version" >&2
  exit 1
fi

arch="x86_64"
configuration="release"
output_path=""
bundle_id=""
icon_path=""
should_sign=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      arch="${2:-}"
      shift 2
      ;;
    --configuration)
      configuration="${2:-}"
      shift 2
      ;;
    --output)
      output_path="${2:-}"
      shift 2
      ;;
    --bundle-id)
      bundle_id="${2:-}"
      shift 2
      ;;
    --icon)
      icon_path="${2:-}"
      shift 2
      ;;
    --no-sign)
      should_sign=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$arch" in
  x86_64|arm64|universal) ;;
  *)
    echo "--arch must be x86_64, arm64, or universal" >&2
    exit 2
    ;;
esac

case "$configuration" in
  debug|release) ;;
  *)
    echo "--configuration must be debug or release" >&2
    exit 2
    ;;
esac

if [[ -z "$output_path" ]]; then
  output_path="$repo_root/.build/dist/ReplayCenter-$app_version-$arch.dmg"
fi

app_path="$repo_root/.build/dmg-stage/$arch-$configuration/ReplayCenter.app"
dmg_root="$repo_root/.build/dmg-root/$arch-$configuration"

build_args=(
  --arch "$arch"
  --configuration "$configuration"
  --output "$app_path"
)
if [[ -n "$bundle_id" ]]; then
  build_args+=(--bundle-id "$bundle_id")
fi
if [[ -n "$icon_path" ]]; then
  build_args+=(--icon "$icon_path")
fi
if [[ "$should_sign" -eq 0 ]]; then
  build_args+=(--no-sign)
fi

"$repo_root/scripts/build-app.sh" "${build_args[@]}"

echo "==> Creating DMG staging folder"
rm -rf "$dmg_root"
mkdir -p "$dmg_root"
ditto "$app_path" "$dmg_root/ReplayCenter.app"
ln -s /Applications "$dmg_root/Applications"

mkdir -p "$(dirname "$output_path")"
rm -f "$output_path"

echo "==> Creating DMG: $output_path"
hdiutil create \
  -volname "ReplayCenter" \
  -srcfolder "$dmg_root" \
  -ov \
  -format UDZO \
  "$output_path"

echo "==> Built $output_path"
