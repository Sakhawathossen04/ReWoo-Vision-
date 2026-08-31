# ReWoo Vision

Controller-free, Bangla-first visual assistance app for blind and low-vision users.

The original app used an 8BitDo controller as a fast hardware shortcut layer. This version removes the controller from the primary workflow and makes Bengali voice commands the main interaction method while preserving the original on-device Gemma 3n vision pipeline.

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
- Existing Hugging Face model-download flow and on-device Gemma inference are preserved

## Core voice commands

| Command | Action |
|---|---|
| `সামনে কী আছে` / `সামনে কী দেখছো` | Capture a photo and describe the current forward view |
| `এদিকে দেখো` | Describe the current camera view |
| `এটা কী` | Identify the main centered object |
| `ডান পাশে কী আছে` | Describe the right side of the **current camera frame** |
| `বাম পাশে কী আছে` | Describe the left side of the **current camera frame** |
| `লেখাটা পড়ে শোনাও` | Capture a photo and try to read visible text |
| `আবার বলো` | Repeat the last AI answer |
| `চুপ করো` | Stop current speech |
| `কী কী বলতে পারি` | Read the available commands |
| `নতুন আলাপ` | Clear the current Gemma chat history |

A few spelling variants and polite prefixes such as `একটু` and `দয়া করে` are supported. The matcher intentionally avoids broad substring matching to reduce accidental activation.

## Runtime flow

```text
App opens
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
Command listening remains/restarts
```

## Important technical limitation: continuous listening

The current implementation deliberately stays on the repository's existing `speech_to_text` stack to minimize build risk and keep the app easy to run. It maintains a foreground command-recognition loop using status-based restart plus a watchdog timer.

However, `speech_to_text` is a wrapper around the phone's speech-recognition service and is designed primarily for commands/short phrases rather than guaranteed true always-on keyword spotting. Therefore:

- behavior can vary by Android device and installed speech service;
- some devices can require network access for Bengali recognition unless offline Bengali speech recognition is installed;
- an uninterrupted one-hour session must be tested on the actual target phone;
- this implementation is not speaker verification: another person saying the same supported command can also activate it.

For a production-grade fully offline always-on listener, the next research upgrade should be a dedicated Bengali streaming ASR/KWS engine such as an evaluated on-device model. Do not claim that capability until it is benchmarked on the target hardware.

## Bengali OCR limitation

The original app used Google ML Kit Latin text recognition as an OCR helper. This version uses that OCR only as an optional hint during the `লেখাটা পড়ে শোনাও` action and asks Gemma to verify the image. Bengali-script OCR quality must be evaluated separately; the app does not falsely claim that the Latin ML Kit recognizer is a Bengali OCR engine.

## Model strategy

The base model remains:

```text
gemma-3n-E2B-it-int4.task
```

The app maps Bengali fixed commands to deterministic intents and then sends a specialized English task instruction with a strict Bengali response constraint. This avoids retraining unless testing proves that the pretrained model is insufficient.

## Recommended development environment

The repository declares Dart SDK `^3.8.1`. A safe matching baseline is:

- Flutter 3.32.x with Dart 3.8.x
- Android Studio + Android SDK
- NDK `27.0.12077973` (pinned by the project)
- A physical Android phone; `minSdk = 24`
- Bengali voice recognition enabled in the phone's speech service
- A Bengali TTS voice installed/enabled
- Stable Wi-Fi for the first Gemma model download (~3 GB)

## Run

```bash
git clone <your-copy-of-this-repository>
cd gemma-vision-bangla
flutter clean
flutter pub get
flutter doctor -v
flutter devices
flutter run
```

Or, after extracting the supplied ZIP:

```bash
cd gemma-vision-bangla
flutter clean
flutter pub get
flutter run
```

## Build an APK

```bash
flutter clean
flutter pub get
flutter build apk --release
```

Expected output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

See `BUILD_AND_TEST.md` for the full beginner-safe procedure.

## Hugging Face OAuth / package-name warning

The original project uses:

```text
Android applicationId: com.tommasogiovannini.gemma
OAuth redirect: com.tommasogiovannini.gemma://oauthredirect
```

This adaptation intentionally leaves those values unchanged so the existing model-download flow has the best chance of continuing to work. Do **not** rename the package or OAuth URI casually. For an independently branded production app, register your own Hugging Face OAuth client/redirect URI first and then update the Android application ID and manifest together.

If the original APK is already installed on the test phone, uninstall it before installing a locally built APK if Android reports a signature mismatch.

## Release signing

The inherited `android/app/build.gradle.kts` still signs the release build with a debug key. That is acceptable only for local demos/direct testing. For Play Store or production distribution, create a proper upload keystore and replace the signing configuration.

## Safety boundary

This app provides **visual assistance and environmental awareness**. A monocular vision-language model can miss obstacles, misread text, hallucinate, or answer with latency. It must not be presented as an autonomous navigation system or as a replacement for a white cane, guide dog, orientation-and-mobility practice, or other safety methods.

## Project documents

- `BUILD_AND_TEST.md` — exact Windows/Android run and APK-build steps
- `ROADMAP_STATUS.md` — what from the project roadmap is implemented and what still requires empirical research
