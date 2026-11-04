# Unsit

macOS menu bar app (SwiftUI + AppKit, macOS 14+) that gets you to 10,000 steps and enough water during the workday. It reads the calendar (EventKit), finds the gaps between meetings, nudges you to walk when a gap is open and you're behind pace. Steps come from the iPhone: the "Unsit Sync" Apple shortcut writes `steps.json` to iCloud Drive › Shortcuts › Unsit, and the app reads it every 15 s. For Macs without that iCloud (work laptops), the shortcut also POSTs the same text to `https://ntfy.sh/unsit-<code>` (Get Contents of URL, Request Body File = Text); each Mac with the same code polls `/json?poll=1&since=latest` every 60 s. Newest reading from today wins (`applyReadings`). Tested by Jorge with curl on 2026-11-04: works. No Apple Developer account needed (HealthKit isn't on macOS).

Owner: Jorge Sousa (github.com/jorgesousa). Repo is meant to live at `jorgesousa/Unsit`; README links, badges and the in-app update check depend on that name (`UnsitConfig.repo`).

## Build and test

```bash
swift test                     # UnsitCore tests (needs Xcode)
scripts/build-app.sh --open    # build, install to /Applications, open
SIGN_IDENTITY="Unsit Local" scripts/build-app.sh --open   # keeps calendar permission between builds
```

`build-app.sh` runs `swift build -c release`, assembles `Unsit.app` with `Resources/Info.plist` and `Resources/AppIcon.icns`, signs ad-hoc (or with `SIGN_IDENTITY`). CI: `.github/workflows/build.yml` runs both on macos-14.

## Layout

- `Sources/UnsitCore` — platform-independent logic (`UpdateCheck`), unit tested in `Tests/UnsitCoreTests`.
- `Sources/Unsit/UnsitApp.swift` — the whole app: `UnsitConfig`, `AppDelegate`, `MenuBarController` + `MenuPanel` (our own NSPanel under an NSStatusItem, deliberately not MenuBarExtra: its system container showed translucent bands above and below the content), `WindowRouter` (setup and settings windows via AppKit), `UnsitModel`, `PanelView`, `DayStrip`, `WaterCups`, `NudgePanelController`, `SettingsTabs` (NSTabViewController, toolbar style: General, iPhone, Author), `UpdateChecker`, `OnboardingView`.
- `docs/` — icon, real panel screenshot, `unsit.mp4` + `demo.webp` (made with /brag).

## Conventions

- **Versioning (like neteinstein/Calendar-Sync):** every change that lands on main bumps `CFBundleShortVersionString` (patch) and `CFBundleVersion` (+1) in `Resources/Info.plist`, and the version badge in README. New features bump the minor. Releases tagged `v<version>`. Current: 0.3.0 (build 5), not yet released.
- **Design system "A, native premium":** graphite #16181B, paper #FBFBFC, mist #CDD1D7 (meetings), signal orange #FF5A1F (only for time to move / warnings), water blue #2F7DF6 (only water). SF Pro, sentence case, no decoration. Motion: ease-out cubic-bezier(0.23, 1, 0.32, 1), under 300 ms, scale 0.95–0.97 on press.
- **Panel top (decided):** left = steps "of 10 000 steps"; right = time "free of meetings today". The bottom-right line only appears for warnings ("1 240 behind pace", "… of walking won't fit"). How much to walk lives in the gap line under the strip.
- **Copy:** English UI, plain verbs, specific numbers. Walking time assumes 100 steps/min.
- Jorge talks in Portuguese (pt-PT); keep the app's UI in English.

## Licence

Sustainable Use License 1.0 (`SUL-1.0`), same as Calendar-Sync: `LICENSE.md` + README badge and section.

## Open items

- Repo is live at github.com/jorgesousa/Unsit (public); CI is green on macos-14. Its older Swift is stricter about concurrency than local Xcode: in `Task { @MainActor … }` inside a `[weak self]` closure, capture `[weak self]` again.
- `UnsitConfig.shortcutLink` is still a placeholder; needs the iCloud link of the shared "Unsit Sync" shortcut (the setup QR code uses it).
- Water sync between Macs over the same ntfy code (water is still per Mac).
- Pre-fill the ntfy action in the shared shortcut with an Import Question asking for the code.
- Later ideas, not started: other app modes (Jorge wants them, design first), goal-reached moment, configurable walking pace, desktop widgets (need paid account), Android phones as a steps source ("coming soon" in README).
- Next step, decided: Homebrew like Calendar-Sync — a **formula** (not a cask) in `jorgesousa/homebrew-tap` that builds from source, so no quarantine or notarization. Install: `brew install jorgesousa/tap/unsit`. Needs: tag `v<version>`, `Formula/unsit.rb` (model: neteinstein/homebrew-tap), app links itself into `~/Applications` on first run, `brew services` for open at login, README install section + tap badge.
