#!/bin/zsh
# Builds, signs, notarizes and publishes Claude Keeper as a GitHub release. See docs/releasing.md.
#   ./release.sh            release Version.swift's version, or the next patch if that one is tagged
#   ./release.sh 0.2.0      release this version
#   ./release.sh redo       delete the latest release and its tag, then release the next patch with its notes
# NOTES=file overrides the notes, which default to the commit subjects since the previous tag.
# Also publishes the Sparkle feed (appcast.xml), signed with the EdDSA key in the login keychain; see docs/updates.md.
set -euo pipefail
cd "${0:A:h}"

identity=${SIGN_IDENTITY:-"Developer ID Application: Nevyn Bengtsson (M4Q2TE45WT)"}
team=${identity##*\(}; team=${team%\)}
profile=${NOTARY_PROFILE:-dibs-notary}
keychain=${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}
version_file=Sources/claude-keeper/Version.swift
dist=dist
app="$dist/Claude Keeper.app"
zip=$dist/Claude-Keeper.zip
appcast=$dist/appcast.xml
sparkle_bin=.build/artifacts/sparkle/Sparkle/bin
sparkle_account=claude-keeper
repo_url=https://github.com/nevyn/claude-keeper

die() { print -u2 "release: $*"; exit 1 }
current() { sed -nE 's/^let version = "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' $version_file }
next_patch() { local v=(${(s:.:)1}); print "$v[1].$v[2].$((v[3] + 1))" }
tagged() { git ls-remote --exit-code --tags origin "refs/tags/v$1" >/dev/null }
zip_app() {
  rm -f $zip
  xattr -cr "$app"
  ditto -c -k --keepParent --norsrc "$app" $zip
  # AppleDouble entries make Gatekeeper reject the app when something other than Archive Utility unzips it.
  [[ "$(unzip -l $zip)" != *"/._"* ]] || die "$zip contains AppleDouble (._) entries"
}

[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
[[ "$(git branch --show-current)" == main ]] || die "not on main"
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main differs from origin/main; pull or push first"
[[ -x $sparkle_bin/generate_appcast ]] || die "$sparkle_bin/generate_appcast is missing; run swift package resolve"
public_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" app/Info.plist)
keychain_key=$($sparkle_bin/generate_keys --account $sparkle_account -p) || die "no Sparkle signing key for account $sparkle_account in the login keychain; see docs/updates.md"
[[ $keychain_key == $public_key ]] || die "the Sparkle key for account $sparkle_account does not match SUPublicEDKey in app/Info.plist"

notes=$(mktemp -t claude-keeper-notes)
version=$(current)
[[ -n $version ]] || die "cannot read the version from $version_file"
case ${1:-} in
  redo)
    if ! tagged $version; then die "v$version is not tagged, so there is nothing to redo; run ./release.sh"; fi
    gh release view "v$version" --json body -q .body > $notes
    gh release delete "v$version" --yes --cleanup-tag
    git tag -d "v$version" 2>/dev/null || true
    version=$(next_patch $version) ;;
  "") if tagged $version; then version=$(next_patch $version); fi ;;
  <->.<->.<->) if tagged $1; then die "v$1 is already released"; fi; version=$1 ;;
  *) die "usage: ./release.sh [version | redo]" ;;
esac
[[ -n ${NOTES:-} ]] && cp $NOTES $notes
if [[ ! -s $notes ]]; then
  previous=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  git log --no-merges --format='- %s' ${previous:+$previous..}HEAD > $notes
fi
print "Releasing v$version with notes:"; cat $notes

if [[ "$(current)" != $version ]]; then
  print "let version = \"$version\"" > $version_file
  git commit -q -m "Release $version" $version_file
fi

SIGN_IDENTITY=$identity scripts/build-app.sh
exe="$app/Contents/MacOS/ClaudeKeeper"
[[ "$("$exe" version)" == $version ]] || die "built app reports $("$exe" version), expected $version"
"$exe" selftest
[[ "$(codesign -dv "$app" 2>&1)" == *$'\nTeamIdentifier='$team$'\n'* ]] || die "signature lacks TeamIdentifier=$team"

zip_app
submission=$(xcrun notarytool submit $zip --keychain-profile $profile --keychain $keychain --wait)
print -r -- $submission
[[ $submission == *"status: Accepted"* ]] || die "notarization was not accepted; see xcrun notarytool log <id> --keychain-profile $profile --keychain $keychain"
xcrun stapler staple "$app"
spctl --assess --type execute -vv "$app"
zip_app  # again, now with the stapled ticket
(cd $dist && shasum -a 256 ${zip:t} > ${zip:t}.sha256)

# The feed lists only this release: generate_appcast sees just its zip and notes.
feed_dir=$(mktemp -d -t claude-keeper-appcast)
cp $zip $feed_dir/
cp $notes $feed_dir/${zip:t:r}.md
rm -f $appcast
$sparkle_bin/generate_appcast --account $sparkle_account --embed-release-notes \
  --download-url-prefix "$repo_url/releases/download/v$version/" -o $PWD/$appcast $feed_dir
feed=$(<$appcast)
[[ $feed == *"<sparkle:version>$version</sparkle:version>"* && $feed == *"sparkle:edSignature="* ]] || die "$appcast does not offer a signed v$version; see $feed_dir"

git tag "v$version"
git push -q origin main "v$version"
gh release create "v$version" $zip $zip.sha256 $appcast --title "v$version" --notes-file $notes --latest
rm -f $notes

check=$(mktemp -d -t claude-keeper-check)
curl -fsSL -o $check/${zip:t} "$repo_url/releases/download/v$version/${zip:t}"
cmp -s $check/${zip:t} $zip || die "downloaded zip differs from $zip"
curl -fsSL -o $check/appcast.xml "$repo_url/releases/latest/download/appcast.xml"
[[ "$(<$check/appcast.xml)" == *"<sparkle:version>$version</sparkle:version>"* ]] || die "$repo_url/releases/latest/download/appcast.xml does not offer v$version; see $check/appcast.xml"
print "Released v$version; the download matches $zip, and the feed offers it."
