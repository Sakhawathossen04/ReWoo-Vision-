# ReWoo Vision

Controller-free, Bangla-first visual assistance app for blind and low-vision users.

The original app used an 8BitDo controller as a fast hardware shortcut layer. This version removes the controller from the primary workflow and makes Bengali voice commands the main interaction method while preserving the original on-device Gemma 3n vision pipeline.

## What's new in this release (v1.2)

| # | Problem | Fix |
|---|---|---|
| 1 | Users had to log into Hugging Face in a browser to download the model | **Automatic Hugging Face authentication** — the app ships with a developer read token. Users only create a simple in-app account (email + password + consent checkbox) and the model downloads itself |
| 2 | Model download stopped when the app went to the background | `allowCellular: true` (mobile-data downloads), foreground-service notification, storage-low guard removed, **auto-retry/auto-resume** (up to 5 attempts) and full recovery after app restarts |
| 3 | Microphone died after the first command | The command loop restarts after **every** command, after every TTS announcement, on `notListening`/`done`, and via an 8-second watchdog. A dead TTS engine can no longer freeze the loop (all `speak()` calls are timeout-protected) |
| 4 | No wake-word activation | Optional **Wake Word mode**: say "রিউ" / "রিউ ভিশন" / "সহায়ক" / "hey assistant" → the assistant primes for 12 seconds and accepts the next command. Toggle in Settings |
| 5 | The primary command "সামনে কী আছে দেখো" was not detected | The matcher was rebuilt: word-boundary containment, trailing-verb tolerance (দেখো/বলো/শোনাও…), polite prefixes, and a conservative fuzzy pass (Levenshtein ≥ 0.85) for recogniser noise. Covered by unit tests |
| 6 | No sound in the output on some phones | New `TtsEngineService`: picks Google TTS when present, probes bn-BD → bn-IN → bn voices with graceful fallback, requests audio focus on every utterance (`focus: true`), and every speak call is hang-proof. A one-tap **কণ্ঠস্বর পরীক্ষা** in Settings reports the engine/language actually used |
| 7 | Chat did not show the user's real command | The chat now shows the **Bengali text actually spoken** (or the canonical command label) as the user message, followed by the captured image and the AI answer |
| 8 | Conversation lost on restart | Full **conversation history persistence** (last 200 messages incl. images/videos) restored automatically on the chat screen |
| 9 | No photo/video control by voice | New commands: **"ছবি তোলো"** (capture + save + show in chat) and **"ভিডিও রেকর্ড করো" / "ভিডিও বন্ধ করো"** (silent recording so the voice loop stays live, live red banner + stop button, auto-stop after 5 minutes, tap the video bubble to play) |
| 10 | Device compatibility | Explicit microphone + camera permission requests, camera resolution fallback chain (high → medium → low), CPU-first backend, GPU optional |

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
Sign Up / Sign In (email + password)
   ↓
Consent checkbox (অ্যাকাউন্ট তথ্য নিরাপদে ব্যবহৃত হবে)
   ↓
Automatic Hugging Face authentication (developer token, invisible to the user)
   ↓
Automatic model download (background-safe, notification progress)
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

## Developer setup (one time, REQUIRED for automatic downloads)

The end user never sees Hugging Face. Downloads authenticate with your own read token:

1. Open https://huggingface.co/google/gemma-3n-E2B-it-litert-preview with the release account and accept the model license.
2. Create a **Read** token at https://huggingface.co/settings/tokens.
3. Paste it into `lib/download_page/config/constants.dart` (`hfAppToken`), or build with
   `flutter build apk --release --dart-define=HF_APP_TOKEN=hf_your_token`.
4. Rebuild — done.

## Chat history & media

- Conversation history (commands, answers, images, videos) persists locally and reloads on the next app start; "নতুন আলাপ" clears it.
- Voice-captured photos: `<app files>/media/photos/IMG_*.jpg`
- Voice-recorded videos: `<app files>/media/videos/VID_*.mp4` (silent by design so the voice loop keeps working; tap a video bubble to play it).

## Privacy & battery notes

- Accounts live only on the device (salted SHA-256 password hash in local storage).
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
