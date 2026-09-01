# ReWoo Vision

Controller-free, Bangla-first visual assistance app for blind and low-vision users.

The original app used an 8BitDo controller as a fast hardware shortcut layer. This version removes the controller from the primary workflow and makes Bengali voice commands the main interaction method while preserving the original on-device Gemma 3n vision pipeline.

## What's new in this release (v1.3 — download fixed)

| # | Problem | Fix |
|---|---|---|
| 1 | **The model never downloaded** — the app stopped with "ডেভেলপার Hugging Face টোকেন যোগ করা হয়নি" because the previous build required a compiled-in developer token that was never set | **Bulletproof 3-path authentication chain**: bundled developer token (optional) → stored Hugging Face login → **restored proven old-version in-app Hugging Face login** (one tap, one time). The download now works on every build |
| 2 | The in-app email Sign Up / Sign In screen is gone | Removed completely — the app opens straight to the model download page, like the old version |
| 3 | Model download stopped when the app went to the background | `allowCellular: true` (mobile-data downloads), foreground-service notification, storage-low guard removed, **auto-retry/auto-resume** (up to 5 attempts) and full recovery after app restarts |
| 4 | Microphone died after the first command | The command loop restarts after **every** command, after every TTS announcement, on `notListening`/`done`, and via an 8-second watchdog. A dead TTS engine can no longer freeze the loop (all `speak()` calls are timeout-protected) |
| 5 | No wake-word activation | Optional **Wake Word mode**: say "রিউ" / "রিউ ভিশন" / "সহায়ক" / "hey assistant" → the assistant primes for 12 seconds and accepts the next command. Toggle in Settings |
| 6 | The primary command "সামনে কী আছে দেখো" was not detected | The matcher was rebuilt: word-boundary containment, trailing-verb tolerance (দেখো/বলো/শোনাও…), polite prefixes, and a conservative fuzzy pass (Levenshtein ≥ 0.85) for recogniser noise. Covered by unit tests |
| 7 | No sound in the output on some phones | New `TtsEngineService`: picks Google TTS when present, probes bn-BD → bn-IN → bn voices with graceful fallback, requests audio focus on every utterance (`focus: true`), and **auto-retries with engine re-configuration** when an utterance produces no sound. A one-tap **কণ্ঠস্বর পরীক্ষা** in Settings reports the engine/language actually used |
| 8 | Chat did not show the user's real command | The chat now shows the **Bengali text actually spoken** (or the canonical command label) as the user message, followed by the captured image and the AI answer |
| 9 | Conversation lost on restart | Full **conversation history persistence** (last 200 messages incl. images/videos) restored automatically on the chat screen |
| 10 | No photo/video control by voice | New commands: **"ছবি তোলো"** (capture + save + show in chat) and **"ভিডিও রেকর্ড করো" / "ভিডিও বন্ধ করো"** (silent recording so the voice loop stays live, live red banner + stop button, auto-stop after 5 minutes, tap the video bubble to play) |
| 11 | Device compatibility | Explicit microphone + camera permission requests, camera resolution fallback chain (high → medium → low), **automatic GPU → CPU fallback** when a phone's GPU cannot load the model, CPU-first backend |

## What this version does

- Bengali-first interface and accessibility announcements
- No 8BitDo/controller requirement
- Fixed Bengali voice commands are matched deterministically in the app
- Unrelated recognized speech is ignored
- Voice listener automatically restarts while the chat page remains in the foreground
- Camera is normally closed and opens only after a vision command
- One photo is captured, the camera is disposed, then Gemma inference begins
- Gemma 3n E2B IT Int4 remains the base vision-language model; no unnecessary retraining is introduced
- AI prompts force concise Bengali answers and prioritize useful visual information
- Bengali TTS reads the response automatically
- Bengali-aware streaming sentence splitting supports `।`, `.`, `?`, and `!`
- Touch/type controls remain as a fallback

## First-run user flow

```text
App opens
   ↓
Model download page (no sign-up / sign-in screen)
   ↓
Access resolved automatically:
   • developer token compiled in → 100% automatic, no login ever
   • previous Hugging Face login stored → automatic
   • otherwise → user presses ডাউনলোড once →
       one-time Hugging Face login (in-app browser) → token saved
   ↓
Model download (background-safe, notification progress, resumable)
   ↓
Download complete → Voice assistant ready
```

## Core voice commands

| Command | Action |
|---|---|
| `সামনে কী আছে (দেখো)` | Capture a photo and describe the current forward view |
| `এদিকে দেখো` | Describe the current camera view |
| `এটা কী` | Identify the main centered object |
| `ডান পাশে কী আছে` | Describe the right side of the **current camera frame** |
| `বাম পাশে কী আছে` | Describe the left side of the **current camera frame** |
| `লেখাটা পড়ে শোনাও` / `সামনে কী লেখা আছে` | Capture a photo and try to read visible text |
| `ছবি তোলো` | Capture a photo, save it, show it in chat |
| `ভিডিও রেকর্ড করো` | Start recording (say `ভিডিও বন্ধ করো` to stop) |
| `ভিডিও বন্ধ করো` | Stop recording and save the video |
| `আবার বলো` | Repeat the last AI answer |
| `চুপ করো` | Stop current speech |
| `কী কী বলতে পারি` | Read the available commands |
| `নতুন আলাপ` | Clear the current Gemma chat history |

Wake words (when Wake Word mode is enabled): `রিউ`, `রিউ ভিশন`, `সহায়ক`, `হে সহায়ক`, `hey assistant`.

A few spelling variants and polite prefixes such as `একটু` and `দয়া করে` are supported. The matcher intentionally avoids broad substring matching to reduce accidental activation.

## Runtime flow

```text
App opens
   ↓
Sign up / sign in (first run only)
   ↓
Model auto-downloads (first run only, background-safe)
   ↓
Bengali command listening starts
   ↓
Unrelated speech → ignored
Recognized fixed command → intent
   ↓
Camera opens only if the intent needs vision
   ↓
Capture one image
   ↓
Camera closes
   ↓
Intent-specific prompt + image → Gemma 3n
   ↓
Concise Bengali response
   ↓
Bengali TTS
   ↓
Chat shows: user command + captured image + AI answer
   ↓
Microphone returns to listening automatically
```

## Deployment (GitHub Actions APK build — recommended)

The APK is built automatically by `.github/workflows/build-apk.yml` on every push to `main`.
Download it from **Actions → Build Android APK → artifacts → gemma-vision-bangla-apk**.

**How authentication behaves in the APK:**

- **Without any secret (default):** the app works out of the box. Each user does a ONE-TIME
  Hugging Face login from the download page (one tap, in-app browser). The login is stored
  and every later download is fully automatic. If the model license was not accepted yet,
  the app opens the license page and lets the user continue right after accepting.

- **Optional — fully automatic for everyone:** add the repository secret
  `HF_APP_TOKEN` (GitHub → Settings → Secrets and variables → Actions → New repository secret):

  1. Open https://huggingface.co/google/gemma-3n-E2B-it-litert-preview with your release
     account and accept the model license (one time).
  2. Create a **Read** token at https://huggingface.co/settings/tokens (starts with `hf_`).
  3. Add it as the secret `HF_APP_TOKEN` and re-run the workflow.

  The workflow compiles it in with `--dart-define=HF_APP_TOKEN=…`. End users then never
  see any login at all. Keep the token secret — anyone who extracts it could download
  gated models under your account.

## Chat history & media

- Conversation history (commands, answers, images, videos) persists locally and reloads on the next app start; "নতুন আলাপ" clears it.
- Voice-captured photos: `<app files>/media/photos/IMG_*.jpg`
- Voice-recorded videos: `<app files>/media/videos/VID_*.mp4` (silent by design so the voice loop keeps working; tap a video bubble to play it).

## Privacy & battery notes

- No account system — nothing to sign up for; the optional Hugging Face login token stays on the device.
- The microphone is only active while the app is on screen — never in the background.
- The global wakelock was removed; downloads rely on the WorkManager foreground service, and recording uses a short-lived wakelock.

## Building & testing

See `BUILD_AND_TEST.md` for the full toolchain setup, and run:

```bash
flutter pub get
flutter analyze   # zero errors expected
flutter test      # command matcher tests
flutter build apk --release
```
