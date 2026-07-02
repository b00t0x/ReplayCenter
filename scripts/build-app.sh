#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-app.sh [options]

Build ReplayCenter.app from SwiftPM products.

Options:
  --arch ARCH       Build architecture: x86_64, arm64, or universal.
                    Defaults to x86_64 for fast local packaging checks.
  --configuration  SwiftPM configuration: release or debug. Defaults to release.
  --output PATH    Output .app path. Defaults to .build/app/ReplayCenter.app.
  --bundle-id ID   CFBundleIdentifier. Defaults to org.b00t0x.ReplayCenter.
  --icon PATH      App icon source, either .icns or Icon Composer .icon.
                   Defaults to Resources/AppIcon.icns or Resources/AppIcon.icon
                   when either exists.
  --no-sign        Skip ad-hoc codesigning.
  -h, --help       Show this help.

Environment:
  SWIFT            Swift executable. Defaults to ~/.swiftly/bin/swift when it
                   exists, otherwise swift from PATH.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/module-cache}"
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

swift_bin="${SWIFT:-}"
if [[ -z "$swift_bin" ]]; then
  if [[ -x "$HOME/.swiftly/bin/swift" ]]; then
    swift_bin="$HOME/.swiftly/bin/swift"
  else
    swift_bin="swift"
  fi
fi

arch="x86_64"
configuration="release"
output_path="$repo_root/.build/app/ReplayCenter.app"
bundle_id="org.b00t0x.ReplayCenter"
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

config_flag="debug"
if [[ "$configuration" == "release" ]]; then
  config_flag="release"
fi

products=(ReplayCenter ReplayCenterStreamFilter)
stage_dir="$repo_root/.build/app-stage/$arch-$configuration"
build_output_dir="$stage_dir/products"

absolute_path() {
  local path="$1"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s\n' "$repo_root/$path" ;;
  esac
}

build_product_for_arch() {
  local product="$1"
  local build_arch="$2"

  echo "==> Building $product [$build_arch, $configuration]"
  (
    cd "$repo_root"
    "$swift_bin" build \
      -c "$config_flag" \
      --arch "$build_arch" \
      --product "$product"
  )
}

product_path() {
  local build_arch="$1"
  local product="$2"
  printf '%s/.build/%s-apple-macosx/%s/%s' \
    "$repo_root" "$build_arch" "$configuration" "$product"
}

prepare_products() {
  rm -rf "$stage_dir"
  mkdir -p "$build_output_dir"

  if [[ "$arch" == "universal" ]]; then
    for product in "${products[@]}"; do
      build_product_for_arch "$product" arm64
      build_product_for_arch "$product" x86_64

      local arm64_path
      local x86_64_path
      arm64_path="$(product_path arm64 "$product")"
      x86_64_path="$(product_path x86_64 "$product")"

      if [[ ! -x "$arm64_path" || ! -x "$x86_64_path" ]]; then
        echo "Missing product for universal build: $product" >&2
        exit 1
      fi

      echo "==> Creating universal $product"
      lipo -create "$arm64_path" "$x86_64_path" -output "$build_output_dir/$product"
      chmod 755 "$build_output_dir/$product"
    done
  else
    for product in "${products[@]}"; do
      build_product_for_arch "$product" "$arch"

      local built_path
      built_path="$(product_path "$arch" "$product")"
      if [[ ! -x "$built_path" ]]; then
        echo "Missing product: $built_path" >&2
        exit 1
      fi

      cp "$built_path" "$build_output_dir/$product"
      chmod 755 "$build_output_dir/$product"
    done
  fi
}

default_icon_path() {
  if [[ -f "$repo_root/Resources/AppIcon.icns" ]]; then
    printf '%s\n' "$repo_root/Resources/AppIcon.icns"
  elif [[ -d "$repo_root/Resources/AppIcon.icon" ]]; then
    printf '%s\n' "$repo_root/Resources/AppIcon.icon"
  fi
}

compile_icon_composer_asset() {
  local source_icon="$1"
  local resources_dir="$2"
  if ! xcrun --find actool >/dev/null 2>&1; then
    echo "Xcode actool not found. Install Xcode or pass a .icns with --icon." >&2
    exit 1
  fi

  local staged_icon="$stage_dir/AppIcon.icon"
  local partial_plist="$stage_dir/AppIcon.partial-info.plist"
  rm -rf "$staged_icon"
  rm -f "$partial_plist"
  ditto "$source_icon" "$staged_icon"

  xcrun actool "$staged_icon" \
    --compile "$resources_dir" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$partial_plist" \
    --warnings \
    --errors \
    --notices \
    --output-format human-readable-text

  if [[ ! -f "$resources_dir/Assets.car" || ! -f "$resources_dir/AppIcon.icns" ]]; then
    echo "actool did not produce the expected icon assets." >&2
    exit 1
  fi
}

install_icon_if_available() {
  local resources_dir="$1"
  local info_plist="$2"
  local source_icon="$icon_path"
  if [[ -z "$source_icon" ]]; then
    source_icon="$(default_icon_path)"
  else
    source_icon="$(absolute_path "$source_icon")"
  fi

  [[ -n "$source_icon" ]] || return 0

  case "$source_icon" in
    *.icns)
      if [[ ! -f "$source_icon" ]]; then
        echo "Icon file not found: $source_icon" >&2
        exit 1
      fi
      cp "$source_icon" "$resources_dir/AppIcon.icns"
      ;;
    *.icon)
      if [[ ! -d "$source_icon" ]]; then
        echo "Icon Composer document not found: $source_icon" >&2
        exit 1
      fi
      compile_icon_composer_asset "$source_icon" "$resources_dir"
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$info_plist" >/dev/null
      ;;
    *)
      echo "Unsupported icon format: $source_icon" >&2
      exit 1
      ;;
  esac

  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$info_plist" >/dev/null
}

create_bundle() {
  local app_path="$1"
  local contents_dir="$app_path/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"

  echo "==> Creating app bundle: $app_path"
  rm -rf "$app_path"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$build_output_dir/ReplayCenter" "$macos_dir/ReplayCenter"
  cp "$build_output_dir/ReplayCenterStreamFilter" "$macos_dir/ReplayCenterStreamFilter"

  cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja</string>
  <key>CFBundleDisplayName</key>
  <string>ReplayCenter</string>
  <key>CFBundleExecutable</key>
  <string>ReplayCenter</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ReplayCenter</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$app_version</string>
  <key>CFBundleVersion</key>
  <string>$app_version</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>EPGStation に接続してライブ TV ストリームと番組情報を取得するため、ローカルネットワークへのアクセスを使用します。</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  install_icon_if_available "$resources_dir" "$contents_dir/Info.plist"

  plutil -lint "$contents_dir/Info.plist" >/dev/null

  if [[ "$should_sign" -eq 1 ]]; then
    echo "==> Ad-hoc signing app bundle"
    codesign --force --sign - "$macos_dir/ReplayCenterStreamFilter"
    codesign --force --sign - "$macos_dir/ReplayCenter"
    codesign --force --sign - "$app_path"
  fi

  echo "==> Built $app_path"
}

verify_bundle() {
  local verify_args=("$output_path" --arch "$arch")
  if [[ "$should_sign" -eq 0 ]]; then
    verify_args+=(--skip-codesign)
  fi
  "$repo_root/scripts/verify-app.sh" "${verify_args[@]}"
}

prepare_products
create_bundle "$output_path"
verify_bundle
