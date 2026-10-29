# The app and its agent

`Claude Keeper.app` has one executable, `Contents/MacOS/ClaudeKeeper`, with two roles:

* Opened from Finder (no arguments), it shows the setup window. It never runs in the background.
* Started by launchd as `ClaudeKeeper run`, it is the agent. launchd starts it directly, not
  through LaunchServices, so it has no Dock icon or menu.

Both roles have the same code identity (`dev.nevyn.ClaudeKeeper`, team M4Q2TE45WT), so the
Accessibility grant that the setup window asks for applies to the agent, and the window's
`AXIsProcessTrusted()` check reports the agent's grant.

## Registration

The setup window registers `Contents/Library/LaunchAgents/dev.nevyn.ClaudeKeeper.agent.plist` with
`SMAppService.agent(plistName:)`. Background Task Management then lists it under Login Items, and
launchd keeps it running (`KeepAlive`). The agent redirects its own output to
`~/Library/Logs/claude-keeper.log`, because a plist inside the bundle cannot name a path in the
user's home.

Register from the app as LaunchServices launches it (Finder, or `open -a … --args agent on`). On
macOS 27, a registration made by running the executable directly, for example over SSH, could
not be unregistered later: `unregister()` failed with "Operation not permitted".

Turning the agent on also removes the v0.1 agent (`~/Library/LaunchAgents/dev.nevyn.claude-keeper.plist`
and its binary), since two keepers would quit and relaunch the same instances.

## Following the bundle

Background Task Management records the agent against the app's path. What happens when that path
changes, measured on macOS 26.6 and 27.0:

* **Replaced by a newer copy** (Finder removes the old bundle, then copies the new one): the
  running agent keeps the old executable open. Registration survives, and launchd starts the new
  executable once the old process exits.
* **Moved to the Trash**: launchd keeps the job and retries the spawn, which fails with exit
  code 78 (`EX_CONFIG`). On macOS 26 the record stays `enabled`. On macOS 27, Background Task
  Management drops its records but still leaves the launchd job loaded.

So the agent checks its bundle every second (`BundleWatch`):

* Its executable has a new inode: it exits, and launchd starts the new version.
* Its executable has been gone for 10 seconds, and a bookmark to the bundle resolves into the
  Trash or not at all: it calls `unregister()` and then boots out its own launchd job, which
  covers the case where Background Task Management dropped the record first.
* The bundle moved elsewhere: it keeps running and logs that the app should be opened in its new
  place.
* Accessibility was granted after it started: it exits so that launchd restarts it, because a
  process caches its `CGPreflightPostEventAccess()` answer.
