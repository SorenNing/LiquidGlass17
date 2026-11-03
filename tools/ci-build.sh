#!/bin/bash
# 在 macOS runner 上构建 LVGlassDock.dylib (arm64e) 并打包 deb
set -euo pipefail
export COPYFILE_DISABLE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64e-apple-ios16.0"
VER="$(awk '/^Version:/{print $2}' control)"
ARCH="$(awk '/^Architecture:/{print $2}' control)"

OUT="$ROOT/build/ci"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "== SDK: $SDK / 版本 $VER / $ARCH"

clang -c -fobjc-arc -O2 -isysroot "$SDK" -target $TARGET \
      -Iclient -Wno-deprecated-declarations \
      -o "$OUT/LVGlassDock.o" client/LVDock.m

clang -target $TARGET -isysroot "$SDK" -dynamiclib \
      -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
      -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
      -undefined dynamic_lookup \
      -install_name "/var/jb/Library/MobileSubstrate/DynamicLibraries/LVGlassDock.dylib" \
      -o "$OUT/LVGlassDock.dylib" "$OUT/LVGlassDock.o"
codesign --force --sign - "$OUT/LVGlassDock.dylib"
file "$OUT/LVGlassDock.dylib"

# 打包
STAGE="$OUT/stage"
mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries"
cp control "$STAGE/DEBIAN/control"
printf '#!/bin/sh\nexit 0\n' > "$STAGE/DEBIAN/postinst"; chmod 755 "$STAGE/DEBIAN/postinst"
cp "$OUT/LVGlassDock.dylib" client/LVGlassDock.plist \
   "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"

mkdir -p dist
DEB="dist/com.ning.lvglass_${VER}_${ARCH}.deb"
rm -f "$DEB"
( cd "$STAGE" && tar --no-mac-metadata -czf "$OUT/data.tar.gz" ./var )
( cd "$STAGE/DEBIAN" && tar --no-mac-metadata -czf "$OUT/control.tar.gz" ./control ./postinst )
echo "2.0" > "$OUT/debian-binary"
( cd "$OUT" && ar rc "$ROOT/$DEB" debian-binary control.tar.gz data.tar.gz )

ls -l "$DEB"
echo "== SHA256"; shasum -a 256 "$DEB"
