#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/verify-app.sh [options] PATH_TO_APP

Verify a ReplayCenter.app bundle.

Options:
  --arch ARCH       Require executable architecture: x86_64, arm64, or universal.
  --skip-codesign  Skip codesign verification for unsigned inspection builds.
  -h, --help       Show this help.
USAGE
}

expected_arch=""
should_verify_codesign=1
app_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      expected_arch="${2:-}"
      shift 2
      ;;
    --skip-codesign)
      should_verify_codesign=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$app_path" ]]; then
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      app_path="$1"
      shift
      ;;
  esac
done

case "$expected_arch" in
  ""|x86_64|arm64|universal) ;;
  *)
    echo "--arch must be x86_64, arm64, or universal" >&2
    exit 2
    ;;
esac

if [[ -z "$app_path" ]]; then
  echo "PATH_TO_APP is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 1
fi

contents_dir="$app_path/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
info_plist="$contents_dir/Info.plist"
main_executable="$macos_dir/ReplayCenter"
filter_executable="$macos_dir/ReplayCenterStreamFilter"

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Required file not found: $path" >&2
    exit 1
  fi
}

require_executable() {
  local path="$1"
  require_file "$path"
  if [[ ! -x "$path" ]]; then
    echo "Required executable is not executable: $path" >&2
    exit 1
  fi
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist"
}

verify_arch() {
  local executable="$1"
  case "$expected_arch" in
    "")
      return 0
      ;;
    universal)
      lipo "$executable" -verify_arch arm64 x86_64 >/dev/null
      ;;
    *)
      lipo "$executable" -verify_arch "$expected_arch" >/dev/null
      ;;
  esac
}

echo "==> Verifying app bundle: $app_path"
require_file "$info_plist"
require_executable "$main_executable"
require_executable "$filter_executable"

plutil -lint "$info_plist" >/dev/null

bundle_executable="$(plist_value CFBundleExecutable)"
bundle_identifier="$(plist_value CFBundleIdentifier)"
short_version="$(plist_value CFBundleShortVersionString)"
bundle_version="$(plist_value CFBundleVersion)"

if [[ "$bundle_executable" != "ReplayCenter" ]]; then
  echo "Unexpected CFBundleExecutable: $bundle_executable" >&2
  exit 1
fi
if [[ -z "$bundle_identifier" ]]; then
  echo "CFBundleIdentifier is empty" >&2
  exit 1
fi
if [[ ! "$short_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Invalid CFBundleShortVersionString: $short_version" >&2
  exit 1
fi
if [[ "$bundle_version" != "$short_version" ]]; then
  echo "CFBundleVersion differs from CFBundleShortVersionString: $bundle_version / $short_version" >&2
  exit 1
fi

verify_arch "$main_executable"
verify_arch "$filter_executable"

if /usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$info_plist" >/dev/null 2>&1; then
  require_file "$resources_dir/Assets.car"
fi
if /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$info_plist" >/dev/null 2>&1; then
  require_file "$resources_dir/AppIcon.icns"
fi

if [[ "$should_verify_codesign" -eq 1 ]]; then
  codesign --verify --deep --strict "$app_path"
else
  echo "==> Skipping codesign verification"
fi

file "$main_executable"
file "$filter_executable"
echo "==> App bundle verification passed"
