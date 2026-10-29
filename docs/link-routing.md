# Link routing

Claude Keeper can take over `claude://` links and forward each one to the instance that should
open it. Without it, LaunchServices gives every link to one instance (in practice the default
instance), so a connector sign-in started in a Parall instance completes in the wrong one.

Link routing is off until the user turns it on in the setup window. The setup window shows the
step only when there are two or more instances. Turning it on creates `link-routing-on` in the
state directory (`~/Library/Application Support/claude-keeper`), claims the scheme, and asks for
the Automation permission against a running instance.

## How a link travels

1. Claude Keeper declares the `claude` scheme in its Info.plist, and the agent makes it the
   scheme's default handler (`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`).
   Claiming a custom scheme shows no dialog.
2. On a click, LaunchServices gives the link to a running Claude Keeper process (the setup
   window or an earlier router) or launches one. A launched process sees the `GURL` Apple
   Event before `applicationDidFinishLaunching`, and then acts as the **router** instead of
   opening the setup window. It quits once it has no links left.
3. The router classifies the link, picks an instance (see Routing), and sends the instance's
   process a `kInternetEventClass`/`kAEGetURL` Apple Event addressed by pid. Claude's
   `open-url` handler opens the link and brings its window forward.

LaunchServices cannot target a pid. Opening a link "with" a Parall bundle only activates that
instance and drops the link, and opening it with `Claude.app` reaches whichever instance
LaunchServices picks. So forwarding needs Apple Events, and with them the Automation permission
("Claude Keeper wants to control Claude"). TCC keys that grant on Claude's bundle ID, so one grant
covers every instance and survives relaunches.

## Routing

| Link | Goes to |
|---|---|
| Sign-in link: `claude://claude.ai/magic-link…`, `…/sso-callback…`, `…/mcp-auth-callback…`, `claude://login/…` | the last-active instance, without asking |
| Any other link | the chooser, with the last-active instance preselected; the only running instance if there is one |

A sign-in link completes a flow that the user started in an instance moments earlier, so the
last-active instance is the one that started it. Opening a magic link in the other instance
would sign that instance in to the wrong account, so sign-in links never go to more than one instance.

The **last-active instance** is the instance that was most recently frontmost. The agent samples
`NSWorkspace.frontmostApplication` every tick (it stays current without a run loop) and writes
`last-active.json` (instance name, pid, time) to the state directory when it changes. Window
z-order cannot replace this: it only covers the current desktop.

The **chooser** is a panel at the mouse pointer that lists the running instances with their
icons. It highlights the last-active instance, or the first one when there is none. Return opens
the highlighted one, Up and Down or the pointer move the highlight, 1–9 or a click pick one, and
Esc or a click outside drops the link. A link that needs the chooser while it is up waits its
turn, because a second panel would take key status from the first and so drop its link. Links
that need no chooser are forwarded meanwhile.

## Failing open

When the router cannot forward a link (Automation denied, no running instance, the send
fails or the Automation prompt times out, no last-active instance for a sign-in link), it opens the link with `Claude.app`
through LaunchServices. That is the behaviour without link routing, and it needs no grant; a
cold Claude buffers the link until its window is ready. The router never logs a link's query,
because sign-in links carry codes.

## Keeping the scheme

Every instance makes itself the scheme's handler 5–11 s after it launches. While link routing
is on, the agent compares the handler with its own bundle every tick and claims the scheme
again, so links clicked in the second after a launch still go to Claude directly. Turning link
routing off, turning the keeper off, or moving the app to the Trash hands the scheme back to
`Claude.app`.

Turning the keeper off keeps `link-routing-on`, so turning it on again resumes link routing. While
the keeper is off, nothing claims the scheme back, so the setup window asks for the keeper too.

Claude decides at launch whether it owns the scheme. It then finishes connector sign-ins with a
`claude://` callback, which the router forwards. Google sign-in asks at sign-in time and uses
ASWebAuthenticationSession when it does not own the scheme; that callback never leaves the instance.

## Not covered

* `msauth.com.anthropic.claudefordesktop` (Microsoft sign-in) still goes to one instance.
* Handoff and Spotlight continuations (`continue-activity`) still go to the instance that
  LaunchServices picks.
* Claude handles `https://claude.ai` universal links in code, but has no associated-domains
  entitlement yet. If it gets one, those links reach Claude without passing through the router.
