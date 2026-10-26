#!/usr/bin/env bash
# Builds DirCompare.app into ./build, signed for local use.
#
#   scripts/build-app.sh            build ./build/DirCompare.app
#   scripts/build-app.sh --install  also copy it to ~/Applications
#   scripts/build-app.sh --open     also launch it

set -euo pipefail

cd "$(dirname "$0")/.."

install=false
open_app=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        --open) open_app=true ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

app=build/DirCompare.app
icon=build/AppIcon.icns

echo "==> Building release binary"
swift build -c release --product DirCompare
bin_dir=$(swift build -c release --show-bin-path)

if [[ ! -f "$icon" || scripts/make-icon.swift -nt "$icon" ]]; then
    echo "==> Rendering app icon"
    rm -rf build/AppIcon.iconset
    mkdir -p build
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil --convert icns --output "$icon" build/AppIcon.iconset
fi

echo "==> Assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DirCompare" "$app/Contents/MacOS/DirCompare"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"

if $install; then
    dest="$HOME/Applications/DirCompare.app"
    echo "==> Installing to $dest"
    mkdir -p "$HOME/Applications"
    rm -rf "$dest"
    ditto "$app" "$dest"
    app="$dest"
fi

if $open_app; then
    open "$app"
fi

echo "Done: $app"
