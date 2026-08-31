// lib/auth/auth_service.dart
//
// Local first-run account system for ReWoo Vision.
//
// Goal (Priority 1): the end user must NEVER see a Hugging Face login.
// The user creates a simple in-app account (email + password + consent).
// Hugging Face access is handled automatically inside the app using a
// developer-provided access token (see download_page/config/constants.dart).

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Result object so the UI can show clean Bengali error messages.
class AuthResult {
  final bool success;
  final String? error;

  const AuthResult._(this.success, this.error);

  const AuthResult.ok() : success = true, error = null;
  const AuthResult.failure(String message) : success = false, error = message;
}

/// Account record kept in local storage (never leaves the device).
class _StoredUser {
  final String email;
  final String salt;
  final String passwordHash;
  final DateTime createdAt;

  _StoredUser({
    required this.email,
    required this.salt,
    required this.passwordHash,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'email': email,
    'salt': salt,
    'passwordHash': passwordHash,
    'createdAt': createdAt.toIso8601String(),
  };

  static _StoredUser fromJson(Map<String, dynamic> json) => _StoredUser(
    email: json['email'] as String,
    salt: json['salt'] as String,
    passwordHash: json['passwordHash'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class AuthService {
  AuthService._();

  // Storage keys (namespaced to avoid clashes with other modules).
  static const String _usersKey = 'rewoo_users_v1';
  static const String _sessionKey = 'rewoo_session_v1';
  static const String _consentPrefix = 'rewoo_consent_v1_';
  static const String _consentVersion = '1';

  /// The consent message shown next to the checkbox on the auth screen.
  /// Wording requested by the product owner — do not change casually.
  static const String consentMessage =
      'আমি সম্মতি দিচ্ছি যে, আমার অ্যাপ Authentication তথ্য নিরাপদভাবে '
      'Hugging Face Authentication এবং প্রয়োজনীয় Model Access-এর জন্য '
      'ব্যবহার করা হবে।';

  static final RegExp _emailRx = RegExp(
    r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
    caseSensitive: false,
  );

  // ────────────────────────────────────────────────────────────
  // Validation
  // ────────────────────────────────────────────────────────────

  /// Returns a Bengali error string, or null when the input is valid.
  static String? validateCredentials(String email, String password) {
    final cleanEmail = email.trim().toLowerCase();
    if (cleanEmail.isEmpty) return 'ইমেইল ঠিকানা লিখুন।';
    if (!_emailRx.hasMatch(cleanEmail)) {
      return 'ইমেইল ঠিকানাটি সঠিক নয়। যেমন: name@gmail.com';
    }
    if (password.length < 6) {
      return 'পাসওয়ার্ড কমপক্ষে ৬ অক্ষরের হতে হবে।';
    }
    if (password.length > 128) {
      return 'পাসওয়ার্ড খুব বড় হয়ে গেছে।';
    }
    return null;
  }

  // ────────────────────────────────────────────────────────────
  // Account creation / sign in
  // ────────────────────────────────────────────────────────────

  /// Creates a new local account and stores the consent flag.
  static Future<AuthResult> signUp({
    required String email,
    required String password,
    required bool consentGiven,
  }) async {
    final cleanEmail = email.trim().toLowerCase();

    final validationError = validateCredentials(cleanEmail, password);
    if (validationError != null) {
      return AuthResult.failure(validationError);
    }
    if (!consentGiven) {
      return AuthResult.failure(
        'চালিয়ে যেতে অনুগ্রহ করে সম্মতির বক্সে টিক দিন।',
      );
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final users = _readUsers(prefs);

      if (users.containsKey(cleanEmail)) {
        return AuthResult.failure(
          'এই ইমেইল দিয়ে অ্যাকাউন্ট আগেই তৈরি। সাইন ইন করুন।',
        );
      }

      final salt = _generateSalt();
      final user = _StoredUser(
        email: cleanEmail,
        salt: salt,
        passwordHash: _hashPassword(password, salt),
        createdAt: DateTime.now(),
      );

      users[cleanEmail] = user.toJson();
      await prefs.setString(_usersKey, json.encode(users));

      await _recordConsent(prefs, cleanEmail);
      await prefs.setString(_sessionKey, cleanEmail);

      debugPrint('[AuthService] account created for $cleanEmail');
      return const AuthResult.ok();
    } catch (e) {
      debugPrint('[AuthService] signUp error: $e');
      return AuthResult.failure('অ্যাকাউন্ট তৈরি করা যায়নি। আবার চেষ্টা করুন।');
    }
  }

  /// Signs into an existing local account.
  static Future<AuthResult> signIn({
    required String email,
    required String password,
    required bool consentGiven,
  }) async {
    final cleanEmail = email.trim().toLowerCase();

    if (cleanEmail.isEmpty || password.isEmpty) {
      return AuthResult.failure('ইমেইল ও পাসওয়ার্ড দুটোই লিখুন।');
    }
    if (!consentGiven) {
      return AuthResult.failure(
        'চালিয়ে যেতে অনুগ্রহ করে সম্মতির বক্সে টিক দিন।',
      );
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final users = _readUsers(prefs);

      final stored = users[cleanEmail];
      if (stored == null) {
        return AuthResult.failure(
          'এই ইমেইলে কোনো অ্যাকাউন্ট নেই। আগে সাইন আপ করুন।',
        );
      }

      final user = _StoredUser.fromJson(stored);
      final candidate = _hashPassword(password, user.salt);
      if (candidate != user.passwordHash) {
        return AuthResult.failure('পাসওয়ার্ড সঠিক নয়। আবার চেষ্টা করুন।');
      }

      await _recordConsent(prefs, cleanEmail);
      await prefs.setString(_sessionKey, cleanEmail);

      debugPrint('[AuthService] signed in as $cleanEmail');
      return const AuthResult.ok();
    } catch (e) {
      debugPrint('[AuthService] signIn error: $e');
      return AuthResult.failure('সাইন ইন করা যায়নি। আবার চেষ্টা করুন।');
    }
  }

  // ────────────────────────────────────────────────────────────
  // Session helpers
  // ────────────────────────────────────────────────────────────

  /// True when a user already completed sign-in on this device.
  static Future<bool> hasSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString(_sessionKey);
      if (email == null || email.isEmpty) return false;
      return _readUsers(prefs).containsKey(email);
    } catch (_) {
      return false;
    }
  }

  static Future<String?> currentEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_sessionKey);
    } catch (_) {
      return null;
    }
  }

  /// Signs out. Downloaded model files are kept — only auth state is cleared.
  static Future<void> signOut() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionKey);
    } catch (e) {
      debugPrint('[AuthService] signOut error: $e');
    }
  }

  static Future<bool> hasConsent(String email) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(
        '$_consentPrefix${email.trim().toLowerCase()}',
      );
      if (raw == null) return false;
      final data = json.decode(raw);
      return data is Map && data['version'] == _consentVersion;
    } catch (_) {
      return false;
    }
  }

  // ────────────────────────────────────────────────────────────
  // Internals
  // ────────────────────────────────────────────────────────────

  static Map<String, dynamic> _readUsers(SharedPreferences prefs) {
    final raw = prefs.getString(_usersKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return {};
    } catch (_) {
      return {};
    }
  }

  static Future<void> _recordConsent(
    SharedPreferences prefs,
    String email,
  ) async {
    await prefs.setString(
      '$_consentPrefix$email',
      json.encode({
        'version': _consentVersion,
        'acceptedAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  static String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String _hashPassword(String password, String salt) {
    final bytes = utf8.encode('$salt:$password');
    return sha256.convert(bytes).toString();
  }
}
