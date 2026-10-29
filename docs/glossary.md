# Glossary

**Claude Keeper**: the app. Its executable is both the **setup window** (opened from Finder) and
the **agent** (started by launchd with `run`). Avoid "wizard" and "daemon".

**Instance**: one copy of Claude desktop with its own user-data dir: `/Applications/Claude.app`
or a Parall copy of it. Not "app" or "window".

**Default instance**: `/Applications/Claude.app`, the one ShipIt relaunches. Avoid "unprefixed"
in code; it is fine in prose aimed at Parall users.

**Update attempt**: the `update-attempt` file that an instance writes into its user-data dir when
it quits itself to install an update, and that its next launch consumes.

**Owed instance**: an instance that is down because it quit for an update, or because the keeper
quit it, and that the keeper must relaunch.

**Blocking**: an update attempt is blocking while the installed version still equals its
`fromVersion`, which means that running instances keep ShipIt from installing.

**Session**: one Claude Code CLI process under an instance, plus the tools that it runs.
**Quiet**: an instance whose sessions have all been idle for 5 minutes.

**Placement**: the desktop (Space ID and its 1-based number) where an instance's largest window
was last seen.

**Link**: a `claude://` URL. Avoid "deep link" and "universal link"; Claude has no universal links.

**Router**: the role in which Claude Keeper receives a link from LaunchServices and forwards it to
an instance. Avoid "interceptor" and "proxy".

**Sign-in link**: a link that completes a flow that the user started in one instance (magic link,
SSO callback, connector sign-in callback, `claude://login/`).

**Last-active instance**: the instance that was most recently frontmost, as the agent recorded it.

**Chooser**: the panel in which the user picks the instance that opens a link.
