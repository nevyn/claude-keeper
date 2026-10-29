# Donations

Claude Keeper is free. It asks for a donation twice, then never again. It makes no network calls for
this and has no way to tell whether anyone donated. Both asks open `donationURL`
(`https://ko-fi.com/nevynjpg`) in the default browser.

## The two asks

1. **The setup window's footer.** Once the setup window shows "All set" (`SetupState.done`), its
   footer adds "Claude Keeper is free. If it keeps your Claudes running, consider chipping in €20."
   with a Donate… button. The line stays until the donation reminder has been shown or the user has
   clicked Donate… in either place; after that, the footer only has "All set".
2. **The donation reminder.** 14 days after setup was first completed, the agent launches the app
   once in the `donation-reminder` role, the same way that it launches an update check (see
   [updates.md](updates.md)):

   ```sh
   open -g -n -a "/Applications/Claude Keeper.app" --args donation-reminder
   ```

   The role is an accessory process with one panel: the app icon, "Enjoying Claude Keeper?", a
   sentence about the two weeks and Ko-fi, and the buttons Not Now and Donate…. Either button, or
   closing the panel, quits the role.

   macOS refuses activation to an app that was launched in the background, so the panel is a
   non-activating panel, like the chooser. Unlike the chooser, it sits at normal window level,
   centered on the main screen, and it does not make itself key: it comes up in front of the
   user's windows, goes behind them as soon as the user clicks one, and never takes their
   keystrokes. A click on a button acts at once, without activating the app.

The footer line appears once every setup step is done. The reminder's 14 days count from when setup
was first seen done: by the setup window, or by a running agent, whichever comes first. A running
agent counts because the keeper only runs once the user turned it on, so users who skip the optional
desktop steps, or who upgraded through Sparkle and never reopen the window, are asked too.

## State

One file, `donation.json` in the state directory (`~/Library/Application Support/claude-keeper/`).
Times are seconds since 1970; a missing key means that it has not happened.

```json
{"setupCompleted": 1792000000, "reminderShown": 1793209600, "donateClicked": 1793209630}
```

* `setupCompleted`: the setup window writes it the first time that it sees setup done, and an agent
  running from the app writes it on its first tick if it is still missing. Nothing overwrites it.
* `reminderShown`: the `donation-reminder` role writes it as soon as its panel is on screen, so the
  reminder shows at most once, even if the user never answers it.
* `donateClicked`: the first click on Donate…, in either place.

The agent reads the file once a minute and launches the role when `donationReminderDue` says so (the
selftest covers it). When the role never gets its panel on screen, the agent launches it again an
hour later. The role checks the file too, and quits without a window if the reminder has been shown
or the user has clicked Donate….

## Testing

Run these on a test Mac, never on a Mac where the keeper is in real use. To start over, delete
`donation.json`. To get the reminder from the agent without waiting 14 days, backdate the
completion time; the agent launches the reminder within a minute:

```sh
echo "{\"setupCompleted\": $(( $(date +%s) - 15 * 86400 ))}" > ~/Library/Application\ Support/claude-keeper/donation.json
```

The role also shows the reminder when launched by hand with the `open` command above, as long as the
file has no `reminderShown` and no `donateClicked`.

`claude-keeper snapshot <dir>` renders the footer (`done-donation-*.png`) and the reminder
(`donation-reminder-*.png`) without showing them.
