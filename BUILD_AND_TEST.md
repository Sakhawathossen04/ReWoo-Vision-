# Gemma Vision বাংলা — Build and Test Guide

Follow the steps in order. Do not rename the Android package before the first successful end-to-end run.

> NOTE (v1.2): The old browser-based Hugging Face OAuth flow has been REPLACED by an automatic, developer-token based download. Users only create a simple in-app account (email + password + consent). See section 1.1 below.

### 1.1 REQUIRED one-time setup: Hugging Face token (automatic downloads)

End users never log into Hugging Face. The app authenticates downloads with
YOUR developer access token:

1. Sign in to the Hugging Face account you use for this app release.
2. Open https://huggingface.co/google/gemma-3n-E2B-it-litert-preview and accept
   the model license with that account (one time).
3. Go to https://huggingface.co/settings/tokens → Create new token → type "Read".
4. Paste the token (starts with `hf_`) into
   `lib/download_page/config/constants.dart` → `hfAppToken`
   (replace `PASTE_YOUR_HF_TOKEN_HERE`), **or** build with
   `flutter build apk --release --dart-define=HF_APP_TOKEN=hf_your_token`.
5. Rebuild. From now on the whole pipeline is automatic:
   Sign Up → consent → automatic authentication → automatic download.

Without this token the download page shows a clear setup message and the
automatic download will not start.

## 1. Install tools

On Windows install:

- Git
- Flutter SDK
- Android Studio
- Android SDK Platform Tools
- Android SDK Command-line Tools
- NDK (Side by side) version `27.0.12077973`
- VS Code with Flutter/Dart extensions (optional but convenient)

Run:

```powershell
git --version
flutter --version
flutter doctor -v
```

Then accept Android licenses:

```powershell
flutter doctor --android-licenses
```

## 2. Prepare a physical Android phone

On the phone:

```text
Settings → About phone → tap Build number about 7 times
Settings → Developer options → USB debugging → ON
```

Connect the phone by USB and accept the debugging prompt.

Run:

```powershell
flutter devices
```

The phone must appear as an Android device.

## 3. Extract/open this project

Example:

```powershell
cd C:\projects\gemma-vision-bangla
flutter clean
flutter pub get
```

Do **not** run `flutter pub upgrade` before the baseline works.

## 4. Run the app

```powershell
flutter run
```

First build can take several minutes because Gradle/native dependencies may be downloaded.

## 5. First-run model setup

The Gemma model is not stored in the Git repository. The existing app flow downloads:

```text
gemma-3n-E2B-it-int4.task
```

from the configured Hugging Face model repository. Authentication is automatic (developer token) and the download keeps running in the background on Wi-Fi or mobile data. Ensure several GB of free storage.

## 6. Enable Bengali speech services

For the voice commands to work well, make sure the target phone has Bengali recognition enabled in its system/Google speech settings. If the phone supports downloadable offline Bengali speech recognition, install it.

Also make sure a Bengali TTS voice is installed. The app requests `bn-BD` and falls back to the platform's available voice if necessary.

## 7. End-to-end functional test

Test in this order:

1. App opens and announces readiness in Bengali.
2. Say `সামনে কী আছে` — a camera capture should occur only after the command.
3. Confirm the camera closes before Gemma generation begins.
4. Confirm the answer is Bengali and automatically spoken.
5. Say an unrelated sentence — it should not execute an app action.
6. Say `এটা কী` — object identification should run.
7. Say `লেখাটা পড়ে শোনাও` — text-reading mode should run.
8. Say `আবার বলো` — last answer should repeat without a new photo.
9. Say `চুপ করো` during speech — speech should stop.
10. Say `নতুন আলাপ` — chat history should reset.

## 8. Continuous-listening stress test

The implementation restarts the device speech recognizer when it stops and has an additional watchdog. Still, the platform recognizer is not a guaranteed true always-on KWS engine, so validate the exact phone.

Run controlled sessions:

```text
15 minutes → 30 minutes → 60 minutes
```

Record:

- successful command detections
- missed commands
- false activations
- whether listener ever stops permanently
- device temperature
- battery drop
- average command-to-first-audio latency

Suggested target metrics:

```text
Command recall ≥ 90%
False activation ≤ 5%
Bangla response rate ≥ 95%
Useful visual answer ≥ 80% (human-rated)
No permanent listener failure in a 60-minute foreground test
```

## 9. Noise test

Repeat fixed commands under:

- quiet room
- fan noise
- TV/conversation in background
- traffic noise
- 0.5 m, 1 m and 2 m speaking distance

Important: the app filters by recognized command text, not by speaker identity. A second person saying the same valid command can trigger the action.

## 10. Camera-direction test

`ডান পাশে কী আছে` and `বাম পাশে কী আছে` mean the right/left side **inside the current camera frame**. They do not make the physical camera turn. Do not evaluate these as full 360-degree right/left awareness.

## 11. Bengali visual benchmark

Before deciding to fine-tune Gemma, collect 100–300 examples covering:

- rooms
- roads
- markets
- classrooms
- stairs
- common objects
- local/Bangladesh-specific objects
- Bengali signs/text
- English labels
- low light
- obstacles/hazards

Human-label each answer as:

```text
Correct
Partially correct
Incorrect
Hallucination
Unsafe answer
```

Only consider model adaptation if measured results justify it.

## 12. Build release APK

```powershell
flutter clean
flutter pub get
flutter build apk --release
```

APK path:

```text
build\app\outputs\flutter-apk\app-release.apk
```

If the original Gemma Vision APK is already installed and Android reports an incompatible signature, uninstall the original app first and then install your build.

## 13. Direct-install test

You can install from a connected device workflow or copy the APK to the phone. After installing the release APK, repeat all tests without relying on the debug session.

## 14. Production note

The inherited release config uses debug signing. Before publishing to Google Play:

- create your own upload/release keystore;
- configure release signing;
- choose your own application ID;
- set your own Hugging Face read token (see section 1.1) or inject it with --dart-define=HF_APP_TOKEN=hf_xxx;
- update all package references together;
- conduct accessibility and safety testing on multiple devices.
