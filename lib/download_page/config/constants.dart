// download_page/config/constants.dart
//
// Central configuration for the model download pipeline.
//
// ─────────────────────────────────────────────────────────────────────
// IMPORTANT — DEVELOPER SETUP (one time)
//
// The end user never logs into Hugging Face. The app authenticates the
// download automatically with the developer's access token below.
//
// How to fill this in:
//   1. Create / sign in a Hugging Face account FOR THE APP RELEASE.
//   2. Open https://huggingface.co/google/gemma-3n-E2B-it-litert-preview
//      and accept the model license with that account (required once).
//   3. Go to https://huggingface.co/settings/tokens → "Create new token"
//      → type "Read".
//   4. Paste the token (starts with "hf_...") into hfAppToken below.
//   5. Rebuild the app. Users then get a fully automatic download.
//
// For a production release keep this token out of public repositories and
// consider injecting it at build time (--dart-define) instead.
// ─────────────────────────────────────────────────────────────────────

/// Developer Hugging Face access token used for automatic model downloads.
/// Replace the placeholder below with your own "hf_..." read token.
const String hfAppToken = String.fromEnvironment(
  'HF_APP_TOKEN',
  defaultValue: 'PASTE_YOUR_HF_TOKEN_HERE',
);

/// True when the bundled token looks like a real Hugging Face token.
bool get hfTokenConfigured => hfAppToken.startsWith('hf_');

// ─────────────────────────────────────────────────────────────────────
// Model Download Configuration
// ─────────────────────────────────────────────────────────────────────

const String modelName = 'gemma-3n-E2B-it-int4.task';
const String modelFullName = 'Gemma 3n E2B IT Int4';
const String downloadUrl =
    'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/$modelName?download=true';
const String modelCardUrl =
    'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview';

// ─────────────────────────────────────────────────────────────────────
// SharedPreferences Keys
// ─────────────────────────────────────────────────────────────────────

const String downloadStateKey = 'download_state';
const String downloadTaskIdKey = 'download_task_id';
const String authTokenKey = 'auth_token';
const String codeVerifierKey = 'code_verifier';

/// Keys for the voice experience settings.
const String wakeWordModeKey = 'voice_use_wake_word_mode';
const String wakeWordPrimedUntilKey = 'voice_wake_word_primed_until';

/// Root folder (inside app documents) where captured photos / videos go.
const String mediaFolderName = 'media';
