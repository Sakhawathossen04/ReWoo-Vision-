# Delivery Change Summary

## v1.2 — Priority fixes (auth automation, background download, voice loop, TTS, chat, media)

### Added
- `lib/auth/auth_service.dart` — local email+password accounts (salted SHA-256), session, consent persistence
- `lib/auth/auth_page.dart` — Sign Up / Sign In UI with the product consent checkbox and Bengali TTS guidance
- `lib/chat_page/services/tts_engine_service.dart` — TTS engine/language auto-selection (fixes silent output), audio focus, hang-proof speak with timeout
- `lib/chat_page/services/chat_history_store.dart` — persistent conversation history (messages, images, videos)
- `lib/chat_page/services/media_service.dart` — save/open photos & videos for voice commands
- `android/app/src/main/res/xml/file_paths.xml` — FileProvider paths for media viewing
- Voice intents: `takePhoto`, `startVideo`, `stopVideo` + wake-word commands

### Removed
- Hugging Face browser OAuth flow (`huggingface_oauth.dart`, `token_manager.dart`, `flutter_web_auth_2` dependency, CallbackActivity)
- Global wakelock at app start (battery/OEM kill risk)
- `url_launcher` dependency (no longer used)

### Modified
- `lib/main.dart` — auth gate (AuthPage → ModelDownloadPage → ChatPage)
- `lib/download_page/logic/download_logic.dart` — automatic token auth, auto-start download, auto-retry/resume (5 attempts) using flutter_downloader `retry()`
- `lib/download_page/services/download_manager.dart` — `allowCellular: true`, `requiresStorageNotLow: false`, retry API
- `lib/chat_page/services/speech_service.dart` — continuous-mic hardening, pause/resume, wake-word mode, mic permission
- `lib/chat_page/services/chat_helpers.dart` — Bengali command display, photo/video commands, history hooks, camera permission + resolution fallback
- `lib/chat_page/services/streaming_tts_service.dart` — audio focus + timeout-protected streaming speech
- `lib/chat_page/voice/bengali_voice_commands.dart` — rebuilt matcher (containment, verbs, fuzzy, wake words) incl. "সামনে কী আছে দেখো"
- `lib/chat_page/gemma_vision_chat.dart` — history restore, restart-after-command, recording banner
- `lib/chat_page/widgets/chat_bubble.dart` — video bubbles + timestamps
- `lib/chat_page/widgets/chat_ui_builder.dart` — recording banner
- `lib/settings_page.dart` — wake-word toggle, TTS test, logout
- `android/app/src/main/AndroidManifest.xml` — FileProvider added, OAuth callback removed, VIEW queries for media
- `android/app/src/main/kotlin/.../MainActivity.kt` — `rewoo_vision/media` MethodChannel (open photos/videos)
- `pubspec.yaml` — dependencies updated
- `README.md`, `BUILD_AND_TEST.md` — new flows + required HF token setup
- `test/voice_command_test.dart` — matcher tests for all new behaviour (8 tests)

## Initial delivery
## Added
- `BUILD_AND_TEST.md`
- `ROADMAP_STATUS.md`
- `lib/chat_page/voice/bengali_voice_commands.dart`
- `lib/chat_page/voice/voice_intent.dart`
- `test/voice_command_test.dart`

## Removed
- `android/build/reports/problems/problems-report.html`
- `assets/controller_setup.png`
- `lib/chat_page/handlers/keyboard_handler.dart`
- `test/widget_test.dart`

## Modified
- `README.md`
- `android/app/src/main/AndroidManifest.xml`
- `lib/chat_page/config/system_prompts.dart`
- `lib/chat_page/gemma_vision_chat.dart`
- `lib/chat_page/services/bootstrap_manager.dart`
- `lib/chat_page/services/chat_helpers.dart`
- `lib/chat_page/services/gemma_service.dart`
- `lib/chat_page/services/speech_service.dart`
- `lib/chat_page/services/streaming_tts_service.dart`
- `lib/chat_page/widgets/chat_bubble.dart`
- `lib/chat_page/widgets/chat_ui_builder.dart`
- `lib/chat_page/widgets/prompt_bar.dart`
- `lib/chat_page/widgets/semantic_material_button.dart`
- `lib/download_page/logic/download_logic.dart`
- `lib/download_page/model_download_page.dart`
- `lib/download_page/ui/modern_ui_widgets.dart`
- `lib/download_page/ui/ui_helpers.dart`
- `lib/error_recovery_page.dart`
- `lib/main.dart`
- `lib/settings_page.dart`
- `pubspec.yaml`

## v1.3.0 — Final delivery (Gemma 3n swap verified + AGP 8.11 build fixes)

### Fixed
- `android/app/src/main/AndroidManifest.xml` — removed the obsolete
  `package="..."` attribute. AGP 8.11 (used by this project) fails the build
  when it is present; `namespace` in `android/app/build.gradle.kts` already
  provides the value.
- `.github/workflows/build-apk.yml` — no longer downloads the Android NDK
  (this project compiles no native code; prebuilt MediaPipe .so ship inside
  the flutter_gemma AAR). Installs exactly what AGP needs
  (platform-tools, build-tools 35.0.0, platforms;android-36). Saves ~10
  minutes per cloud build.
- `android/gradle.properties` — Gradle heap raised to 3 GB (Kotlin 2 GB) so
  R8 minification of the release APK never dies with an out-of-memory.
- `.gitignore` — added (was completely missing): keeps .dart_tool/, .gradle/,
  build/ and local machine files out of the repository.
- `lib/chat_page/services/sound_manager.dart` — replaced `print()` with
  `debugPrint()` (release-build log hygiene).

### Verified (senior double-check pass)
- Model: `gemma-3n-E2B-it-int4.task` @ google/gemma-3n-E2B-it-litert-preview —
  exact published size 3,136,226,711 bytes re-confirmed against the Hugging
  Face API; `expectedModelFileSize` matches byte-for-byte (~3.1 GB, down from
  the previous 8 GB setup).
- The model repo is gated (401 without login): the one-time Hugging Face
  OAuth login (old-version flow) is required and fully wired
  (OAuth 2.0 + PKCE, callback activity, token storage, license sheet on 403).
- All 38 Dart files: imports resolve, braces balanced, assets present.
- Adaptive launcher icons (rewoo logo) present in every density + anydpi-v26.
- Release signing material present: `android/key.properties` +
  `rewoo-vision-release.jks` (used by the cloud workflow).
- pubspec.lock resolved versions consistent with pubspec.yaml
  (flutter_gemma 0.10.0, flutter_downloader 1.12.0, flutter_web_auth_2 4.1.0).
