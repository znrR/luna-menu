#!/bin/zsh
# Builds all apps (ad-hoc signed):
#   Luna Menu.app      → secondary (this Mac), installed straight into /Applications
#   Luna Primary.app   → primary (e.g. MacBook), universal, macOS 10.15+, into build/
#   iMac/Luna Menu.app → secondary for older Intel Macs (e.g. iMac late 2012), macOS 10.15+, into build/iMac/
# Note: after every rebuild you may have to grant the Accessibility permission again.
set -e
cd "${0:A:h}"

APP=${APP:-"/Applications/Luna Menu.app"}
pkill -x LunaMenu 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library Sources/Shared/*.swift Sources/Secondary/*.swift -o "$APP/Contents/MacOS/LunaMenu"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force -s - --identifier de.r4sp.lunamenu "$APP"
echo "built: $APP"

# Intel, macOS 10.15+ (iMac late 2012 etc.): recent Command Line Tools ship the Swift compatibility libs
# for arm64 only, so link without them and bundle libswift_Concurrency (back-deployment).
INTEL_FLAGS=(-target x86_64-apple-macos10.15 -runtime-compatibility-version none
  -Xfrontend -disable-autolinking-runtime-compatibility-concurrency
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
CONC=/Library/Developer/CommandLineTools/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib

# bundle <app> <exe> <plist> <id> <arm64-target> <sources...>
bundle() {
  local app=$1 exe=$2 plist=$3 id=$4 armtarget=$5; shift 5
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" build/tmp
  swiftc -O -swift-version 5 -parse-as-library "${INTEL_FLAGS[@]}" "$@" -o build/tmp/$exe-x86_64
  if [[ -n $armtarget ]]; then
    swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos$armtarget "$@" -o build/tmp/$exe-arm64
    lipo -create build/tmp/$exe-x86_64 build/tmp/$exe-arm64 -output "$app/Contents/MacOS/$exe"
  else
    cp build/tmp/$exe-x86_64 "$app/Contents/MacOS/$exe"
  fi
  cp "$CONC" "$app/Contents/Frameworks/"
  cp "$plist" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 10.15" "$app/Contents/Info.plist"
  codesign --force -s - "$app/Contents/Frameworks/libswift_Concurrency.dylib"
  codesign --force -s - --identifier $id "$app"
  (cd "${app:h}" && rm -f "${app:t:r}.zip" && ditto -c -k --keepParent "${app:t}" "${app:t:r}.zip")
  echo "built: $PWD/$app (+ zip)"
}

# Primary: universal
bundle "build/Luna Primary.app" LunaPrimary Resources/Info-Primary.plist de.r4sp.lunaprimary 11.0 \
  Sources/Shared/*.swift Sources/Primary/*.swift

# Secondary for the iMac late 2012: Intel only
bundle "build/iMac/Luna Menu.app" LunaMenu Resources/Info.plist de.r4sp.lunamenu "" \
  Sources/Shared/*.swift Sources/Secondary/*.swift
