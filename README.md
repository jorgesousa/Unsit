<p align="center"><img src="docs/icon.png" width="96" alt="Unsit icon"></p>

# Unsit

Your chair can wait. Unsit is a macOS menu bar app that gets you to 10,000 steps and enough water during the workday. Your steps arrive from your iPhone and Apple Watch on their own; your Mac reads your calendar, finds the gaps between meetings and tells you when to walk.

<p align="center"><img src="docs/menu-bar.png" width="720" alt="Unsit menu bar panel"></p>

- **Menu bar panel:** today's steps, how far behind pace you are, your day with meetings and the next gap, water.
- **Gap nudge:** when a gap opens between meetings and you're behind pace, a strip drops from the top of the screen with exactly how long to walk.
- **Guided setup:** a four-step window on first launch connects your iPhone and calendar.
- **Settings:** your workday hours (any start and end time), daily steps and water goals, glass size, open at login.

The screenshots in `docs/` are design renders.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ or just the command line tools (`xcode-select --install`)
- An iPhone with Apple Health, signed in to the same iCloud account as the Mac

No Apple Developer account is needed to build and use it on your own Mac.

## Install

```bash
git clone <this repo> Unsit
cd Unsit
scripts/build-app.sh --open
```

That builds `Unsit.app`, copies it to `/Applications` and launches it. The setup window opens on first launch.

To only build into `build/Unsit.app` without installing, run `scripts/build-app.sh`.

## Connect your iPhone

Apple Health data isn't available on the Mac, so a free Apple shortcut copies today's steps to iCloud Drive and Unsit reads them from there. The setup window walks you through it:

1. **Add the shortcut.** Scan the QR code in the setup window and tap Add Shortcut.
2. **Run it once** and allow Steps when Health asks. The Mac shows "Connected" with today's steps.
3. **Keep it fresh.** In Shortcuts › Automation, run Unsit Sync at set times through the day and when you open busy apps like Slack, Teams or Mail. Choose Run Immediately with no notification.
4. **Allow calendar access** so Unsit can find the gaps between meetings.

The shortcut writes `iCloud Drive/Shortcuts/Unsit/steps.json`:

```json
{"steps": "4980", "updatedAt": "2026-11-04T14:24:00+00:00"}
```

**Before sharing the repo:** build the Unsit Sync shortcut once, share it from Shortcuts with Copy iCloud Link, and paste the link into `UnsitConfig.shortcutLink` at the top of `Sources/Unsit/UnsitApp.swift`. The setup window turns that link into the QR code. Anyone can also build the shortcut by hand; the setup window has the steps.

## Update

```bash
git pull
scripts/build-app.sh --open
```

### Keep calendar access between builds (optional)

Ad-hoc signed builds look like a new app to macOS after every rebuild, so it asks for calendar access again. To avoid that, create a self-signed certificate once:

1. Open Keychain Access › Certificate Assistant › Create a Certificate.
2. Name it `Unsit Local`, Identity Type **Self Signed Root**, Certificate Type **Code Signing**.
3. Build with it from then on:

```bash
SIGN_IDENTITY="Unsit Local" scripts/build-app.sh --open
```

## Share a ready-made app

Colleagues can always build from source with the steps above. To hand out an app that opens without a Gatekeeper warning, you need the Apple Developer Program (99 USD/year) to sign with Developer ID and notarize:

```bash
xcrun notarytool store-credentials unsit-notary --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
scripts/notarize.sh
```

This produces `build/Unsit.zip`, notarized and stapled.

## Limitations

- **Steps refresh when the shortcut runs**, not live. With the automations above that's usually every hour or more often.
- **No desktop widgets yet.** Widgets need App Groups, which require the paid developer account.
- **No automatic updates.** Pull and rebuild.
- **Not sandboxed**, so it can read the shortcut's file in iCloud Drive. Unsit only reads that one file and your calendar.

## Project layout

```
Package.swift              Swift package (macOS 14)
Sources/Unsit/UnsitApp.swift   the whole app
Resources/Info.plist       bundle settings, calendar permission text
Resources/AppIcon.icns     app icon
scripts/build-app.sh       builds, signs and installs Unsit.app
scripts/notarize.sh        notarizes for sharing (paid account)
docs/                      design renders used in this README
```

## Licence

Not chosen yet. Add a `LICENSE` file before sharing the repo publicly.
