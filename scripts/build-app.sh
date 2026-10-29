#!/bin/zsh
# Builds "dist/Claude Keeper.app" (universal) and signs it with SIGN_IDENTITY, or ad hoc when that is unset.
set -euo pipefail
cd "${0:A:h}/.."
version=$(sed -nE 's/^let version = "(.*)"$/\1/p' Sources/claude-keeper/Version.swift)
app="dist/Claude Keeper.app"
sparkle=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

die() { print -u2 "build-app: $*"; exit 1 }

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/claude-keeper
[[ -d $sparkle ]] || die "$sparkle is missing; run swift package resolve"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/ClaudeKeeper"
[[ "$(otool -l "$app/Contents/MacOS/ClaudeKeeper")" == *" path @executable_path/../Frameworks "* ]] || die "ClaudeKeeper lacks the rpath @executable_path/../Frameworks"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
sed "s/VERSION/$version/g" app/Info.plist > "$app/Contents/Info.plist"
cp app/AppIcon.icns "$app/Contents/Resources/"
cp app/dev.nevyn.ClaudeKeeper.agent.plist "$app/Contents/Library/LaunchAgents/"
plutil -lint -s app/ClaudeKeeper.entitlements "$app/Contents/Info.plist" "$app/Contents/Library/LaunchAgents/dev.nevyn.ClaudeKeeper.agent.plist"

if [[ -n ${SIGN_IDENTITY:-} ]]; then sign=(--options runtime --timestamp -s "$SIGN_IDENTITY"); else sign=(-s -); fi
fw="$app/Contents/Frameworks/Sparkle.framework"
for code in $fw/Versions/B/{XPCServices/Installer.xpc,XPCServices/Downloader.xpc,Updater.app,Autoupdate} $fw; do
  codesign --force "${sign[@]}" "$code"  # inside out, since signing a bundle does not sign the code nested in it
done
codesign --force --entitlements app/ClaudeKeeper.entitlements "${sign[@]}" "$app"
codesign --verify --deep --strict "$app"

if [[ -n ${SIGN_IDENTITY:-} ]]; then
  team=${SIGN_IDENTITY##*\(}; team=${team%\)}
  [[ $team =~ '^[A-Z0-9]{10}$' ]] || die "cannot read a team ID from SIGN_IDENTITY ($SIGN_IDENTITY)"
  # --deep --strict accepts nested code that is signed ad hoc, which notarization and library validation reject.
  find "$app" -type f -print0 | while IFS= read -r -d '' file; do
    [[ "$(file -b "$file")" == Mach-O* ]] || continue
    [[ "$(codesign -dv "$file" 2>&1)" == *$'\nTeamIdentifier='$team$'\n'* ]] || die "$file is not signed by team $team"
  done
fi
print "Built $app $version"
