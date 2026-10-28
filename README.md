# claude-keeper

A LaunchAgent that keeps several Claude desktop instances running through auto-updates, and
relaunches each on the macOS desktop (Space) where it was last seen. It is for people who run
a second copy of Claude with [Parall](https://parall.app), for example one signed in to a work
account and one to a personal account.

Background and the story of how it came about: [nevyn.dev/blog/20261027-two-claude-desktops](https://nevyn.dev/blog/20261027-two-claude-desktops/).

## The problem

Claude installs updates by quitting itself after an idle timeout, and Squirrel's ShipIt then
replaces `/Applications/Claude.app`. ShipIt waits until no process runs that bundle's binary.
A Parall copy is a small launcher that runs the same binary with its own `--user-data-dir`, so
with two instances the update gets stuck: the instance whose idle timer fired quits and stays
down, while the other one holds the install back. When ShipIt finally installs, it relaunches
only the unprefixed Claude.

## Install

Requirements: macOS 13 or later, Claude in `/Applications`, and Parall copies of it in
`/Applications` or `~/Applications`.

```sh
curl -fLO https://github.com/nevyn/claude-keeper/releases/latest/download/claude-keeper.zip
unzip claude-keeper.zip
./claude-keeper install
```

`install` copies the binary to `~/Library/Application Support/claude-keeper/claude-keeper` and
loads the LaunchAgent `dev.nevyn.claude-keeper`, which starts it at login and restarts it if it
exits. Then:

1. Grant `~/Library/Application Support/claude-keeper/claude-keeper` Accessibility in System
   Settings > Privacy & Security > Accessibility. It needs that grant to post the desktop
   shortcuts. Without it, instances still relaunch, but on the current desktop.
2. Enable "Switch to Desktop N" for every desktop involved, in System Settings > Keyboard >
   Keyboard Shortcuts > Mission Control. Any key combination works, since the keeper reads it.

To upgrade, run the same three commands with a newer release. Releases are signed with the same
Developer ID and notarized, so the Accessibility grant stays valid.

To uninstall, run `~/Library/Application\ Support/claude-keeper/claude-keeper uninstall`. It
leaves the state files and the log in place.

## What it does

Every second, the keeper compares what runs with what should run:

1. When Claude quits itself for an update, it writes `update-attempt`
   (`{"fromVersion", "toVersion", "ts"}`) into that instance's user-data dir, and the next
   launch consumes the file. An instance that is down with that file present (and less than
   12 hours old) quit for an update, so it is owed a relaunch. An explicit quit (Cmd-Q) writes
   no such file, and the instance stays quit.
2. While the installed version still equals an owed attempt's `fromVersion`, whatever instances
   still run are blocking the install. Once nobody has touched the keyboard or mouse for
   5 minutes and those instances' Claude Code sessions have been quiet for 5 minutes, the keeper
   quits them the way Cmd-Q does (SIGTERM after 60 s), and they are owed a relaunch too.
3. Once the new version is installed, and 10 seconds have passed for ShipIt's own relaunch of
   the unprefixed instance, the keeper launches every owed instance that is still down, the
   unprefixed one first, each on its saved desktop.
4. If every instance is down for 3 minutes and ShipIt still has not installed, the keeper
   relaunches them on the old version and stops quitting instances for that update.

A session is a `.../claude-code/...` CLI process under the instance, plus the tools that it runs.
It counts as busy while its transcript (`~/.claude/projects/*/<session-id>.jsonl`) changes, or
while its processes use more than about 3% of a core, which an idle CLI does not.

Instances are `/Applications/Claude.app` plus every app bundle in `/Applications` or
`~/Applications` whose Info.plist has `ParallAppBundleId = com.anthropic.claudefordesktop`.
A running instance is told apart by its main process's `--user-data-dir` argument.

About every 5 seconds the keeper saves each instance's desktop, taken from its largest window.
To relaunch an instance, it posts your "Switch to Desktop N" shortcut, launches the instance with
`open -n -g`, waits for its window, and then returns to the desktop that you were on. While the
screen is locked, it relaunches without switching desktops. If ShipIt relaunched the unprefixed
instance on the wrong desktop while it is the only instance, the keeper restarts it there.

The rules are a pure state machine that `claude-keeper selftest` runs against scripted
scenarios. Its state is saved in `update-state.json`, so a keeper restart in the middle of an
update does not forget what it quit.

## Commands

* `claude-keeper status`: instances, pids, current and saved desktops, pending update attempts,
  idle time, and per-session activity (takes 5 seconds)
* `claude-keeper restore [instance...]`: relaunch instances that are not running on their
  saved desktops
* `claude-keeper switch <n>`: switch to desktop n the way the keeper does
* `claude-keeper install`, `claude-keeper uninstall`, `claude-keeper selftest`, `claude-keeper version`

The log is `~/Library/Logs/claude-keeper.log`; state lives in
`~/Library/Application Support/claude-keeper/`.

## Building from source

```sh
swift build -c release
.build/release/claude-keeper selftest
.build/release/claude-keeper install
```

A local build is signed ad hoc, and an ad-hoc signature changes with every build, so each
rebuild needs a new Accessibility grant. Sign it with a certificate of your own to avoid that:
`codesign -f -s "Developer ID Application: …" -i dev.nevyn.claude-keeper .build/release/claude-keeper`.
Maintainers publish releases with `./release.sh`, described in [docs/releasing.md](docs/releasing.md).

## Caveats

* The keeper quits instances on its own. It waits for idle input and quiet sessions, but a
  session that is thinking for more than 5 minutes without writing anything looks quiet.
* `update-attempt` and Claude's quit-for-update behaviour are internals of the Claude app, not
  a documented interface, so a Claude update may change them.
* Reading which desktop a window is on uses private CoreGraphics (CGS) calls. macOS has no
  public API for moving another app's window between desktops, and Dock's "Assign To" setting
  keys on bundle ID, which all instances share. That is why the keeper switches desktops before
  it launches an instance.
* The unprefixed Claude cannot be launched while a Parall copy runs: LaunchServices sees
  Claude.app as running and ignores the request. The keeper launches it first for that reason.

## License

MIT
