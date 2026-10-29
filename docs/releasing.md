# Releasing

`./release.sh` publishes a GitHub release with `Claude-Keeper.zip` (the app, universal and
notarized), its SHA-256, and `appcast.xml`, the Sparkle feed that installed copies update from. Run
it from a clean `main` that matches `origin/main`, on a Mac whose login keychain has the Sparkle
signing key (account `claude-keeper`); see [updates.md](updates.md).

* `./release.sh` releases the version in `Sources/claude-keeper/Version.swift`, or the next
  patch version if that one is already tagged.
* `./release.sh 0.2.0` releases that version.
* `./release.sh redo` deletes the latest release and its tag, then releases the next patch
  version with the same notes. Every build that leaves the machine gets a new version number.
  A run that failed before tagging can simply be re-run; it reuses the version.

The notes default to the commit subjects since the previous tag; `NOTES=file` overrides them.

The script checks the Sparkle key, commits the version bump, builds the app with
`scripts/build-app.sh`, runs `selftest`, notarizes, staples, checks it with `spctl`, generates the
appcast, tags, pushes `main` and the tag, and creates the release. Finally it downloads the zip and
compares it with the local one, and checks that `releases/latest/download/appcast.xml` offers the new
version.

The zip is made without extended attributes or AppleDouble (`._`) entries: Gatekeeper rejects an
app that carries them when something other than Archive Utility unzips it.

## Signing and notarization

`scripts/build-app.sh` signs Sparkle's helpers (its XPC services, `Updater.app` and `Autoupdate`),
then `Sparkle.framework`, then the app, because signing a bundle does not sign the code nested in it.
With `SIGN_IDENTITY` set, it also checks that every Mach-O file in the bundle carries the team ID,
since `codesign --verify --deep --strict` accepts nested code that is signed ad hoc.

The app is signed with identifier `dev.nevyn.ClaudeKeeper` and the Developer ID in
`SIGN_IDENTITY` (default: Nevyn's personal team, M4Q2TE45WT). TCC keys an Accessibility grant on
the designated requirement, which is that identifier plus the team, so upgrading keeps the grant.
Changing either one makes every user grant Accessibility again.

`notarytool` uses the keychain profile in `NOTARY_PROFILE` (default `dibs-notary`) from
`NOTARY_KEYCHAIN` (default: the login keychain). A profile in the login keychain stays readable
while the screen is locked; one in the data-protection keychain does not. To create one:

```sh
xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team> --keychain ~/Library/Keychains/login.keychain-db
```
