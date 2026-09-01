// download_page/config/constants.dart
//
// Central configuration for the model download pipeline.
//
// ─────────────────────────────────────────────────────────────────────
// AUTHENTICATION — three supported paths, tried in this order:
//
//   1. Developer token (zero-touch)   — optional.
//      Set HF_APP_TOKEN at build time (--dart-define) with a "read"
//      token (hf_...) whose account has accepted the Gemma license.
//      End users then NEVER see any login.
//
//   2. Stored Hugging Face login      — zero-touch after first use.
//      The user signs in once with their own Hugging Face account
//      (in-app browser). The token is stored and reused silently.
//
//   3. Hugging Face login (first use) — the proven "old version" flow.
//      OAuth 2.0 + PKCE through huggingface.co. Restored because the
//      developer-token-only build could not download anything.
//
// Optional developer setup (path 1):
//   1. Create / sign in a Hugging Face account FOR THE APP RELEASE.
//   2. Open https://huggingface.co/google/gemma-3n-E2B-it-litert-preview
//      and accept the model license with that account (required once).
//   3. Go to https://huggingface.co/settings/tokens → "Create new token"
//      → type "Read".
//   4. Add the token (starts with "hf_...") as the GitHub Actions secret
//      HF_APP_TOKEN — the APK workflow injects it at build time.
// ─────────────────────────────────────────────────────────────────────

/// Developer Hugging Face access token used for automatic model downloads.
/// Empty/unset means the app falls back to the stored user login or the
/// Hugging Face login flow.
const String hfAppToken = String.fromEnvironment(
  'HF_APP_TOKEN',
  defaultValue: '',
);

/// True when the bundled token looks like a real Hugging Face token.
bool get hfTokenConfigured => hfAppToken.startsWith('hf_');

// ─────────────────────────────────────────────────────────────────────
// Hugging Face OAuth configuration (path 2 + 3 — the proven old flow)
// ─────────────────────────────────────────────────────────────────────

/// OAuth client id registered for this application.
const String hfClientId = '56370c68-410e-4af9-998b-baf53df6cc0c';

/// Deep-link that returns the user to the app after authorization.
const String hfRedirectUri = 'com.tommasogiovannini.gemma://oauthredirect';

/// The URL scheme only (used by flutter_web_auth_2).
const String hfCallbackUrlScheme = 'com.tommasogiovannini.gemma';

const String authEndpoint = 'https://huggingface.co/oauth/authorize';
const String tokenEndpoint = 'https://huggingface.co/oauth/token';
const String scope = 'openid profile read-repos';

// ─────────────────────────────────────────────────────────────────────
// Model Download Configuration
// ─────────────────────────────────────────────────────────────────────

const String modelName = 'gemma-3n-E2B-it-int4.task';
const String modelFullName = 'Gemma 3n E2B IT Int4';
const String downloadUrl =
    'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/$modelName?download=true';
const String modelCardUrl =
    'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview';

/// Exact published size of gemma-3n-E2B-it-int4.task on Hugging Face
/// (3.14 GB). Used to validate a finished download AND to detect stale or
/// partially-downloaded files left by earlier app versions — previously ANY
/// non-empty file was treated as a valid model, which made the app believe
/// a corrupt file was installed and then fail on every launch.
const int expectedModelFileSize = 3136226711;

/// A model file is accepted only when it is within this tolerance of the
/// expected size. Anything smaller is deleted and re-downloaded.
const double modelSizeTolerance = 0.98;

/// App logo (bundled from https://rewoo.tech/assets/logo.jpg).
const String appLogoAsset = 'assets/rewoo_logo.png';

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
