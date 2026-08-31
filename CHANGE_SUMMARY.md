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
