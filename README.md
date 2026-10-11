# ScrollCue — personal iOS teleprompter

A personal teleprompter built to replace a paid app. It has voice tracking, a
floating Picture‑in‑Picture prompter **with up/down scroll buttons**, a video
recording mode, mirroring, presets and remote control.

Personal use only. Not for the App Store.

---

## Install on your iPhone (about 5 minutes)

You need a Mac with **Xcode 16 or newer** and a USB cable (or Wi‑Fi pairing).

1. Get the code:
   ```bash
   git clone https://github.com/kishanb1312-maker/scrollcue-ios.git ScrollCue
   cd ScrollCue
   open ScrollCue.xcodeproj
   ```
2. In Xcode, click the **ScrollCue** project (blue icon, top left), then the **ScrollCue** target, then **Signing & Capabilities**.
   - Check **Automatically manage signing**.
   - **Team**: choose your Apple ID. To add one, go to *Xcode › Settings › Accounts › +*. A free Apple ID works.
   - If Xcode says the bundle ID is taken, change `com.kishanb1312.scrollcue` to anything unique, e.g. `com.yourname.scrollcue`.
3. Plug in your iPhone. Pick it in the device menu at the top of Xcode and press **▶ Run**.
4. First time only:
   - On the iPhone, open **Settings › Privacy & Security › Developer Mode**, turn it on and restart.
   - Then go to **Settings › General › VPN & Device Management**, tap your Apple ID and choose **Trust**.
5. Allow Microphone, Speech Recognition and Camera the first time each is used.

> **Free Apple ID:** the app expires after **7 days**. Plug in and press Run again
> to refresh it (your scripts and settings are kept). A paid developer account
> ($99/yr) makes it last a year.

---

## The floating prompter (PiP) — how scrolling works

1. Open a script, then tap **Start**.
2. Tap the **PiP** button in the dock (rectangle with an arrow). The script pops out into a floating window.
   You can also just swipe home while it's playing if *Start automatically* is on.
3. Open Camera, Instagram, YouTube or any other app. The script floats on top, and the camera doesn't capture it.
4. **Tap the floating window once** to show its controls:

| Button | What it does |
|---|---|
| ⏪ (left skip) | **Scroll UP** by N lines |
| ⏩ (right skip) | **Scroll DOWN** by N lines |
| ⏯ | Play / pause scrolling |

Set N under **Settings › Floating prompter › Up/down buttons move N lines**.

**Why buttons and not finger swipes?** iOS draws the PiP window in a separate
system process and keeps every touch for itself (tap shows the controls, drag
moves the window, pinch resizes it). No app can receive swipes inside a PiP
window, the paid apps included. So ScrollCue takes over the only buttons Apple
allows there. Voice tracking, sound scrolling and constant speed all keep
running in PiP as well.

PiP settings: window shape (landscape, square or portrait), font size, margins,
active line, content rotation, opacity, mic indicator, mirror, step size and
auto‑start.

---

## Features

- **3 scroll modes**
  - **Voice:** on‑device speech recognition follows you word by word and waits when you go off‑script.
  - **Sound:** scrolls while the mic hears you and pauses in silence. Works in any language, with adjustable threshold and speed.
  - **Constant:** fixed speed, no mic.
- **Tap any word** to jump there. **Drag** to scroll by hand.
- **Voice commands** (editable phrases): next/previous sentence, go next, go back, go to start, go to finish, mirror.
- **Language:** auto‑detects the script's language, or pick any of the 60+ languages iOS supports.
- **Display:** SF Rounded, SF Pro, Serif or Monospaced fonts up to 160pt, bold, text/background/highlight colors and quick themes, line and paragraph spacing, margins, alignment, RTL, text and background opacity, active line position and marker, current‑word highlight, dimming of text you've already read, countdown.
- **Mirroring:** horizontal or vertical, for beam‑splitter rigs. Separate PiP mirror.
- **Video mode:** front, 0.5×, 1× or tele lens, 1080p/4K, 24/25/30 fps, 10‑bit HDR (HLG) where the phone supports it. The prompter overlay sits under the lens and avoids the Dynamic Island, and you can drag its bottom handle to resize it. After each take: save to Photos, discard, or keep for later. Leftover takes are under Settings › Recordings.
- **Presets:** save, apply in one tap (also from Quick Settings), update and delete.
- **Customisable dock** and **Quick Settings** sheet over the prompter.
- **Scripts library:** last 100 scripts, search, paste, import .txt/.rtf, duplicate, copy, delete. Each script resumes where you stopped reading.
- **Keyboard / Bluetooth remote:** Space/Enter play, ↑/↓ line, PgUp/PgDn four lines, ←/→ sentence, Home/End, +/- speed, M mirror, R record.
- **Stats:** live word count, lifetime words spoken, sessions, time, milestones.
- **Privacy:** everything stays on the device. No account, no analytics.

## Known limits

- No iCloud sync. Personal (free) signing can't use iCloud.
- Voice tracking in PiP depends on the app in front. Some camera apps take
  exclusive control of the microphone while recording. If voice stops following
  you there, use **Constant** mode plus the ⏪/⏩ buttons.
- A keyboard or remote only controls ScrollCue while ScrollCue is in front. Over
  other apps, use the PiP buttons or voice.

## Project layout

```
ScrollCue.xcodeproj
ScrollCue/
  App/        app entry + tabs
  Models/     settings, presets, scripts, stats
  Engine/     tokenizer, TextKit layout, scroll engine, mic + speech, script matcher
  PiP/        sample-buffer Picture in Picture renderer + controls
  Camera/     capture session + recording
  Views/      SwiftUI screens
Config/Info.plist   background audio mode (keeps PiP alive)
```
