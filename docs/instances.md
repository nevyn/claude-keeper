# Instances and launchers

An instance is Claude desktop running with its own data directory. The default instance is
`/Applications/Claude.app` itself. Every other instance starts from a **launcher**: a small app that
runs Claude's binary with another data directory. Claude Keeper makes its own launchers with
"Add Instance…" in the setup window, and it also recognizes launchers that Parall made.

## Launcher format

"Add Instance…" asks for a name ("Work"), a label and a colour, and writes `Claude (Work).app`
into `/Applications`, or into `~/Applications` when the user cannot write to `/Applications`:

```
Claude (Work).app/Contents/
  Info.plist
  MacOS/launcher            the script below, mode 755
  Resources/AppIcon.icns
  _CodeSignature/           ad hoc signature
```

`MacOS/launcher`:

```sh
#!/bin/sh
exec '/Applications/Claude.app/Contents/MacOS/Claude' '--user-data-dir=/Users/me/Library/Application Support/claude-keeper/instances/work' "$@"
```

Both paths are single-quoted for `sh`, so any character in them is safe.

`Info.plist` has `CFBundleIdentifier` `dev.nevyn.ClaudeKeeper.instance.<slug>`, `CFBundleName` and
`CFBundleDisplayName` `Claude (Work)`, `CFBundleExecutable` `launcher`, `CFBundleIconFile`
`AppIcon`, and Claude Keeper's own keys:

| Key | Value |
|---|---|
| `ClaudeKeeperDataDir` | the data directory; `discoverInstances()` recognizes a launcher by this key |
| `ClaudeKeeperExecutable` | the Claude binary that the script runs |

It also copies `LSMinimumSystemVersion` and every `NS*UsageDescription` key from Claude's
Info.plist at creation time, so that permission prompts read the same as for the default
instance. It declares no URL types, because the router owns `claude://` links; see
[link-routing.md](link-routing.md).

Claude Keeper builds the bundle in a scratch folder on the same volume, signs it with
`codesign --force --sign -`, checks it with `codesign --verify --strict`, and then moves it into
place, so that a failure leaves no half-made launcher. It then registers the launcher with
`LSRegisterURL`, so that Finder, Spotlight and Launchpad show it at once, and opens it so that the
user can sign in.

Claude Keeper is not sandboxed, so the files that it writes carry no quarantine. A launcher
therefore opens without a Gatekeeper prompt and without App Translocation; that was measured
with a hand-made launcher of this format.

## Why the launcher execs Claude

`exec` replaces the script's process with Claude's, so:

* No launcher process stays behind, and quitting the instance quits everything.
* The instance's process runs `/Applications/Claude.app/Contents/MacOS/Claude`. That is the
  process that `runningInstances` looks for, and the one that ShipIt waits for before it installs
  an update, so the update rules in the README apply unchanged.
* Arguments that LaunchServices passes to the launcher reach Claude through `"$@"`.

## Icon and Dock

The icon is Claude's own icon (the file that Claude.app's `CFBundleIconFile` names) with the
label in a coloured pill near the bottom, rendered at every size from 16 to 1024 px and packed
with `iconutil`. Below 64 px the pill has no text, which would be unreadable there. The icon is
made once, so a later Claude update does not change it.

The label shows in Finder, Spotlight, Launchpad and the chooser. The Dock always shows a
running instance with Claude.app's icon: the Dock follows the bundle of the running
executable, and after `exec` that is Claude.app. Parall's launchers get their label into the
Dock only because their bundle is quarantined and runs translocated. Claude Keeper does not try
to imitate that.

## Data directories

A Claude Keeper instance keeps its data in
`~/Library/Application Support/claude-keeper/instances/<slug>`. Claude Keeper creates the
directory and Claude fills it.

The slug comes from the name: lowercase ASCII letters and digits, with a dash between words.
Accents are dropped ("Café" becomes `cafe`), and any other letter or digit becomes its code point
in hex ("日本" becomes `u65e5-u672c`).

Dragging a launcher to the Trash keeps its data. Making an instance with the same name again
uses that data directory, signed in as before. To remove the data too, delete the directory.

The Add Instance sheet rejects a name that:

* is empty, or has no letter or digit;
* contains `/`, `:` or a control character, or makes a file name longer than 255 bytes;
* matches an app in `/Applications` or `~/Applications` by file name or `CFBundleName`,
  ignoring case, which includes a Parall launcher of the same name;
* has the slug of an existing Claude Keeper launcher ("Work!" and "Work" both make `work`).

## Parall launchers

`discoverInstances()` recognizes a Parall launcher by `ParallAppBundleId` =
`com.anthropic.claudefordesktop` in its Info.plist. Parall has two modes:

* **Data directory** (`ParallDataStorage` set): the launcher passes `--user-data-dir`, like Claude
  Keeper's launchers. The data is in `~/Library/Application Support/Parall/<name>`.
* **HOME override** (`ParallDataStorage` empty, `ParallHomeDirectory` set): the launcher sets `HOME`
  instead, so the data is in `<home>/Library/Application Support/Claude`. Its process has no
  `--user-data-dir` argument, so `runningInstances` tells it apart from the default instance by the
  process's `HOME`. It reads that from `KERN_PROCARGS2`, which returns the environment after the
  arguments for any process of the same user (measured on macOS 26.6, also for Claude's hardened
  runtime process). A process whose `HOME` is the user's own home, or that has none, is the
  default instance.
