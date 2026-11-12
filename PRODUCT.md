# Product

<!-- impeccable:product-schema 1 -->

## Platform

web (this record covers the public home page; the product itself is a native macOS menu bar app)

## Stack

Static HTML/CSS/JS, no build step, in `docs/index.html`, served by GitHub Pages from the `/docs` folder at https://jorgesousa.github.io/Unsit/ (same setup as jorgesousa/tab-rehab).

## Users

People who live in meetings: office and remote workers whose Mac calendar is back to back, who want to reach about 10,000 steps and drink enough water during the workday without planning it. They own an iPhone (Apple Health, often an Apple Watch) and may use more than one Mac (home and a work laptop not signed in to their iCloud).

## Product Purpose

Unsit is a macOS menu bar app that syncs with the user's calendar, finds the gaps between meetings, and tells them when to walk and for how long so they keep pace with their own step goal; it also counts water in glasses against their own goal. Success: the user hits the step and water goals they set on a busy day, prompted at the right moment, without planning.

## Positioning

It plans walking around the user's real calendar: it knows where the gaps are and how far behind pace they are, and nudges only when a gap is open ("Walk 15 min now, until 11:30, before Design review"). Step counters count; Unsit finds the time.

## Operating Context

- Calendar: every account in macOS Calendar.app (iCloud, Google, Microsoft 365, Exchange, CalDAV); all-day and "Free" events ignored; re-read every 5 minutes or on ⌘R; calendar data never leaves the Mac.
- Steps: the free "Unsit Sync" Apple shortcut on the iPhone reads Apple Health and sends today's steps to the Mac's private code via ntfy.sh (optionally also a file in iCloud Drive). Every Mac with the same code shows the same steps at once.
- Nudge: a black island grows out of the MacBook notch (or under the menu bar) when a gap opens and the user is more than 300 steps behind pace; Going / In 10 min / skip this gap. Alternative style: the menu bar item turns orange.
- Polite: no nudges during meetings, when away from the Mac, outside the workday, after the goal, or while paused.
- Water in glasses, tap to fill. Pace assumes 100 steps per minute.

## Capabilities and Constraints

- macOS 14 or later; iPhone with Apple Health required for steps. Android "coming soon" (not available).
- Distributed as a free download: `Unsit.dmg` from GitHub Releases, signed with Developer ID and notarized by Apple; or built from source. In-app "Update now" (0.6.0+). Not on the Mac App Store. Homebrew planned, not available.
- Licence: Sustainable Use License 1.0 (source-available, free for personal and internal business use).
- UI language English.

## Brand Commitments

- Name "Unsit", tagline "Your chair can wait." Name confirmed by Jorge on 2026-11-12 after a naming review: known overlaps are the iOS app "Unsit: Stand Up Reminder" (same category), "Unsit Treadmill", small GitHub repos named unsit; unsit.com and unsit.app are taken (unsit.net/.org were available). Strongest alternative considered: "Gapwalk". Run a trademark search before any App Store or paid branding move.
- Voice: calm with dry humour ("Back to back since 9."); plain verbs, specific numbers, sentence case.
- App design system "A, native premium": graphite #16181B, paper #FBFBFC, mist #CDD1D7 (meetings), signal orange #FF5A1F only for time to move and warnings, water blue #2F7DF6 only for water; SF Pro.
- App icon `docs/icon.png`. Author: Jorge Sousa (github.com/jorgesousa).

## Evidence on Hand

- `docs/unsit.mp4` (24 s demo with sound), `docs/demo.gif`, `docs/poster.jpg`; real panel screenshot `docs/menu-bar.png` (older 0.2 layout); demo source in `brag-output/work/scene.html` (faithful HTML rebuild of the island and panel).
- No users, testimonials, press or usage numbers exist. Do not invent any.

## Product Principles

1. Find the time, don't just count steps.
2. Interrupt only when it's useful: a gap is open and you're behind.
3. The user's goals, not ours.
4. Private by default: calendar stays on the Mac; only the step count and time pass through ntfy.sh.
5. Free and open to read.
