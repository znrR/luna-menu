#!/bin/zsh
# Baut beide Apps (ad-hoc signiert):
#   Luna Menu.app     → Secondary (dieser Mac mini), direkt nach /Applications
#   Luna Primary.app  → Primary (MacBook), universal ab 10.15, nach build/
#   iMac/Luna Menu.app → Secondary für iMac late 2012 (Intel, ab 10.15), nach build/iMac/
# Achtung: Nach jedem Neubau muss die Bedienungshilfen-Freigabe ggf. neu gesetzt werden.
set -e
cd "${0:A:h}"

APP=${APP:-"/Applications/Luna Menu.app"}
pkill -x LunaMenu 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library Sources/Shared/*.swift Sources/Secondary/*.swift -o "$APP/Contents/MacOS/LunaMenu"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force -s - --identifier de.r4sp.lunamenu "$APP"
echo "gebaut: $APP"

# Intel ab macOS 10.15 (iMac late 2012 u. ä.): CLT hat die Kompatibilitäts-Libs nur noch für arm64,
# daher ohne sie linken und libswift_Concurrency (Back-Deploy) ins Bundle legen.
INTEL_FLAGS=(-target x86_64-apple-macos10.15 -runtime-compatibility-version none
  -Xfrontend -disable-autolinking-runtime-compatibility-concurrency
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
CONC=/Library/Developer/CommandLineTools/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib

# bundle <app> <exe> <plist> <id> <arm64-target> <quellen...>
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
  echo "gebaut: $PWD/$app (+ zip)"
}

# Primary (MacBook): universal
bundle "build/Luna Primary.app" LunaPrimary Resources/Info-Primary.plist de.r4sp.lunaprimary 11.0 \
  Sources/Shared/*.swift Sources/Primary/*.swift

# Secondary für den iMac late 2012: nur Intel
bundle "build/iMac/Luna Menu.app" LunaMenu Resources/Info.plist de.r4sp.lunamenu "" \
  Sources/Shared/*.swift Sources/Secondary/*.swift
