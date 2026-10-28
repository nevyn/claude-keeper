#!/bin/zsh
# Builds, signs, notarizes and publishes a GitHub release. See docs/releasing.md.
#   ./release.sh            release Version.swift's version, or the next patch if that one is tagged
#   ./release.sh 0.2.0      release this version
#   ./release.sh redo       delete the latest release and its tag, then release the next patch with its notes
# NOTES=file overrides the notes, which default to the commit subjects since the previous tag.
set -euo pipefail
cd "${0:A:h}"

identity=${SIGN_IDENTITY:-"Developer ID Application: Nevyn Bengtsson (M4Q2TE45WT)"}
team=${identity##*\(}; team=${team%\)}
profile=${NOTARY_PROFILE:-dibs-notary}
keychain=${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}
label=dev.nevyn.claude-keeper
version_file=Sources/claude-keeper/Version.swift
dist=dist

die() { print -u2 "release: $*"; exit 1 }
current() { sed -nE 's/^let version = "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' $version_file }
next_patch() { local v=(${(s:.:)1}); print "$v[1].$v[2].$((v[3] + 1))" }
tagged() { git ls-remote --exit-code --tags origin "refs/tags/v$1" >/dev/null }
# spctl and syspolicy_check reject a bare Mach-O, so ask the ticket service that stapler and Gatekeeper use.
has_ticket() {
  local cdhash=$(codesign -dvvv --arch $2 $1 2>&1 | sed -n 's/^CDHash=//p')
  curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"records\":[{\"recordName\":\"2/2/$cdhash\"}]}" \
    https://api.apple-cloudkit.com/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup | grep -q '"signedTicket"'
}

[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
[[ "$(git branch --show-current)" == main ]] || die "not on main"
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main differs from origin/main; pull or push first"

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

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/claude-keeper
[[ "$($bin version)" == $version ]] || die "built binary reports $($bin version), expected $version"
$bin selftest
rm -rf $dist && mkdir -p $dist
cp $bin $dist/claude-keeper
codesign --force --options runtime --timestamp -s "$identity" -i $label $dist/claude-keeper
[[ "$(codesign -dv $dist/claude-keeper 2>&1)" == *$'\nTeamIdentifier='$team$'\n'* ]] || die "signature lacks TeamIdentifier=$team"
codesign --verify --strict -v $dist/claude-keeper

(cd $dist && zip -q -X claude-keeper.zip claude-keeper)
submission=$(xcrun notarytool submit $dist/claude-keeper.zip --keychain-profile $profile --keychain $keychain --wait)
print -r -- $submission
[[ $submission == *"status: Accepted"* ]] || die "notarization was not accepted; see xcrun notarytool log <id> --keychain-profile $profile --keychain $keychain"
for arch in arm64 x86_64; do
  if ! has_ticket $dist/claude-keeper $arch; then die "Apple has no notarization ticket for the $arch slice"; fi
done
(cd $dist && shasum -a 256 claude-keeper.zip > claude-keeper.zip.sha256)

git tag "v$version"
git push -q origin main "v$version"
gh release create "v$version" $dist/claude-keeper.zip $dist/claude-keeper.zip.sha256 --title "v$version" --notes-file $notes
rm -f $notes

check=$(mktemp -d -t claude-keeper-check)
curl -fsSL -o $check/claude-keeper.zip "https://github.com/nevyn/claude-keeper/releases/download/v$version/claude-keeper.zip"
cmp -s $check/claude-keeper.zip $dist/claude-keeper.zip || die "downloaded zip differs from $dist/claude-keeper.zip"
print "Released v$version; the download matches $dist/claude-keeper.zip."
