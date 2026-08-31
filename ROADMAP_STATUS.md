# Roadmap Status

This file maps the agreed project roadmap to the delivered source code.

## Product goal

Transform the original controller-centric Gemma Vision workflow into a controller-free, Bengali-first visual assistance app whose camera is event-driven and whose main interaction is voice.

## Implemented in this source

### 1. Controller removed from primary runtime — DONE

- F-key/8BitDo `KeyboardHandler` is removed from the runtime architecture.
- Controller setup asset is removed.
- Touch controls remain only as fallback.

### 2. Bengali deterministic command router — DONE

Implemented in:

```text
lib/chat_page/voice/voice_intent.dart
lib/chat_page/voice/bengali_voice_commands.dart
```

The application — not Gemma — classifies fixed control commands.

### 3. Foreground continuous command-listening loop — IMPLEMENTED WITH PLATFORM LIMITATION

Implemented in:

```text
lib/chat_page/services/speech_service.dart
```

Features:

- Bengali locale discovery
- fixed-command recognition
- unrelated recognized speech ignored
- automatic status-based restart
- restart watchdog
- permanent-error handling
- listener stops when app leaves foreground and resumes on return

Limitation: this uses `speech_to_text`, not a dedicated offline keyword-spotting model. One-hour reliability is a test criterion, not something that can be guaranteed across all Android speech services without hardware testing.

### 4. Event-driven camera — DONE

Implemented in:

```text
lib/chat_page/services/chat_helpers.dart
```

Flow:

```text
valid visual intent → initialize back camera → capture one image → dispose camera → Gemma inference
```

There is no continuous camera preview in the main flow.

### 5. Intent-aware Gemma prompts — DONE

Implemented in:

```text
lib/chat_page/config/system_prompts.dart
```

Separate instructions are used for front/current/right/left/object/text tasks. The system prompt forces concise Bengali output, uncertainty language, and hazard-first relevance.

### 6. Gemma retraining — INTENTIONALLY NOT DONE

The base model remains `gemma-3n-E2B-it-int4.task`.

Reason: fixed command classification does not need an LLM, and model fine-tuning should only be justified after a Bengali visual benchmark shows a measurable failure that prompt orchestration cannot solve.

### 7. Bengali TTS — DONE

The app requests `bn-BD`, automatically reads AI responses, and localizes status announcements.

### 8. Bengali-aware streaming speech segmentation — DONE

`streaming_tts_service.dart` recognizes Bengali danda (`।`) plus `.`, `?`, `!` and includes Bengali clause-break words.

### 9. Bengali-first UI — DONE

Main chat, settings, download onboarding, recovery UI and primary controls are localized to Bengali.

### 10. OCR strategy — PARTIAL BY DESIGN

The inherited ML Kit Latin recognizer is used only as an optional hint in text-reading mode. Gemma receives the image itself and is told not to invent unreadable text.

A dedicated Bengali OCR engine has not been claimed or fabricated. Bengali OCR accuracy requires empirical evaluation.

### 11. Right/left semantics — SAFETY-CORRECTED

The prompts explicitly define right/left as the right/left side of the **current camera frame**, not the user's entire physical right or left side.

### 12. CPU/GPU backend switching — FIXED

The in-memory Gemma runtime is recreated when backend changes, while the downloaded ~3 GB model is preserved instead of deleted.

## Future research upgrades, only if required by evaluation

### A. True offline keyword spotting / streaming Bengali ASR

A dedicated on-device Bengali KWS/streaming ASR implementation would remove dependence on the phone's speech-recognition service and is the correct production upgrade if continuous-listening tests are not reliable enough.

### B. Speaker verification

Required only if the app must ignore a valid command when it is spoken by someone other than the enrolled user. Keyword matching alone cannot provide speaker identity.

### C. Bengali OCR

Evaluate a dedicated Bengali OCR pipeline if direct Gemma text reading is insufficient.

### D. Model adaptation

Only after benchmark evidence. If needed, prefer parameter-efficient adaptation (for example LoRA/PEFT) over training Gemma from scratch.

## Scientific validation plan

Create an evaluation set and measure:

- command recall / false activation rate;
- 15/30/60 minute listener stability;
- Bengali response rate;
- visual usefulness and hallucination rate;
- text-reading accuracy;
- latency;
- battery/thermal behavior;
- performance across lighting/noise/device conditions.

The source code implements the MVP architecture; these empirical metrics require running the APK on physical target hardware and cannot be truthfully certified by static source inspection alone.
