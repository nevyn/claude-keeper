# Updates

Claude Keeper updates itself with [Sparkle](https://sparkle-project.org) 2, without asking.

## Feed and key

`Info.plist` sets:

* `SUFeedURL`: `https://github.com/nevyn/claude-keeper/releases/latest/download/appcast.xml`. GitHub
  redirects `latest/download` to the asset of the newest release, so the feed is always the newest
  release's `appcast.xml`. Each `appcast.xml` lists only its own release.
* `SUPublicEDKey`: the public half of the Ed25519 key that signs each release's zip. The private half
  is in Nevyn's login keychain under the account `claude-keeper`
  (`generate_keys --account claude-keeper`).
* `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`: Sparkle checks without asking first, and
  downloads and installs updates without showing anything.

`release.sh` (see [releasing.md](releasing.md)) does the Sparkle part of a release:

1. Before building, it checks that the keychain key (`generate_keys --account claude-keeper -p`)
   matches `SUPublicEDKey` in `app/Info.plist`.
2. After notarizing, it runs `generate_appcast` over a directory with just this release's zip and its
   notes (`Claude-Keeper.md`, embedded with `--embed-release-notes`), signing with the keychain key.
3. It uploads `appcast.xml` next to the zip, and finally downloads
   `releases/latest/download/appcast.xml` and checks that it offers the new version.

The Sparkle tools are in `.build/artifacts/sparkle/Sparkle/bin` after `swift package resolve`.

## The update check

The agent cannot run Sparkle: it has no run loop, and launchd starts it outside LaunchServices. So an
hour after it starts, and then once a day, the agent launches the app through LaunchServices:

```sh
open -g -n -a "/Applications/Claude Keeper.app" --args check-for-updates
```

The agent saves the time of each launch in `last-update-check.json` in the state directory, so a
restarted agent (including the restart after an update) waits a day after the previous check. Only an
agent that runs from an app bundle checks.

The `check-for-updates` role is an accessory process without windows. It starts an `SPUUpdater`
with Sparkle's standard user driver, calls `checkForUpdatesInBackground()`, logs every outcome to
`~/Library/Logs/claude-keeper.log`, and quits when Sparkle's update cycle ends: no update, an error,
or an update that is downloaded and ready. It quits after 10 minutes in any case.

Sparkle installs a downloaded update when the process that downloaded it quits. Sparkle also offers
to install it at once, through `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`, but
that path relaunches the app, and an app relaunched without arguments opens the setup window. So the
role declines it and quits instead.

When Sparkle cannot install silently, for example when replacing the app needs an administrator
password, it shows its standard update window from the role instead; the 10-minute limit closes it.

## How the agent picks up the update

Sparkle replaces the bundle at the same path, so `Contents/MacOS/ClaudeKeeper` gets a new inode.
Within a second the agent's `BundleWatch` sees it and exits, and launchd's `KeepAlive` starts the new
executable. The registration and the Accessibility grant survive, as they do when Finder replaces the
app; see [app.md](app.md) and [releasing.md](releasing.md).

## The setup window

The application menu has "Check for Updates…", which runs a check with Sparkle's standard windows.
While the setup window is open, Sparkle also runs its own scheduled checks, and installs a downloaded
update when the window quits.

## Backing up and rotating the key

Export the private key to a file, store it in the password manager, and delete the file:

```sh
generate_keys --account claude-keeper -x claude-keeper-sparkle.key
```

`generate_keys --account claude-keeper -f <file>` imports it on another Mac.

An installed copy accepts an update when either the zip's EdDSA signature verifies against the
installed `SUPublicEDKey`, or the new app is code signed with the same identity as the installed one;
if the old key fails, the zip must verify against the new app's own key (`SUUpdateValidator.m` in
Sparkle). So to rotate the key, or to recover from losing it, generate a new key, put its public half
in `app/Info.plist`, and release as usual: the update is signed with the new key, and installed copies
accept it because the Developer ID team is unchanged. Losing the key and changing the Developer ID
team strands every installed copy.
