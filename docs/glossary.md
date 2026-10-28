# Glossary

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
