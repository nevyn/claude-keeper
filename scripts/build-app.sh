#!/bin/zsh
# Builds "dist/Claude Keeper.app" (universal) and signs it with SIGN_IDENTITY, or ad hoc when that is unset.
set -euo pipefail
cd "${0:A:h}/.."
version=$(sed -nE 's/^let version = "(.*)"$/\1/p' Sources/claude-keeper/Version.swift)
app="dist/Claude Keeper.app"

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/claude-keeper
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
cp "$bin" "$app/Contents/MacOS/ClaudeKeeper"
sed "s/VERSION/$version/g" app/Info.plist > "$app/Contents/Info.plist"
cp app/AppIcon.icns "$app/Contents/Resources/"
cp app/dev.nevyn.ClaudeKeeper.agent.plist "$app/Contents/Library/LaunchAgents/"
plutil -lint -s app/ClaudeKeeper.entitlements "$app/Contents/Info.plist" "$app/Contents/Library/LaunchAgents/dev.nevyn.ClaudeKeeper.agent.plist"
if [[ -n ${SIGN_IDENTITY:-} ]]; then sign=(--options runtime --timestamp -s "$SIGN_IDENTITY"); else sign=(-s -); fi
codesign --force --entitlements app/ClaudeKeeper.entitlements "${sign[@]}" "$app"
codesign --verify --strict "$app"
print "Built $app $version"
