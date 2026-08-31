// lib/auth/auth_page.dart
//
// First-run authentication screen.
//
// New user flow requested by the product owner:
//   App Open → Sign In / Sign Up → Email + Password → Consent Checkbox
//   → Authentication → (automatic) Hugging Face auth → (automatic) model download.
//
// The user never leaves this screen towards Hugging Face.

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'auth_service.dart';
import '../download_page/model_download_page.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _isSignUp = true; // Default to sign-up: first run creates an account.
  bool _consentGiven = false;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  late final FlutterTts _tts;

  @override
  void initState() {
    super.initState();
    _tts = FlutterTts();
    _configureTts();
  }

  Future<void> _configureTts() async {
    try {
      await _tts.setLanguage('bn-BD');
    } catch (_) {
      // Bengali TTS voice may be missing on some devices; the platform
      // default language is an acceptable fallback for one announcement.
    }
    try {
      await _tts.setSpeechRate(0.46);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    _speak(
      'ReWoo Vision এ স্বাগতম। ব্যবহার শুরু করতে ইমেইল ও পাসওয়ার্ড দিয়ে '
      'অ্যাকাউন্ট তৈরি করুন অথবা সাইন ইন করুন।',
    );
  }

  Future<void> _speak(String message) async {
    try {
      await _tts.stop();
      await _tts.speak(message, focus: true);
    } catch (_) {
      // TTS is a convenience here; the form is fully usable without it.
    }
  }

  @override
  void dispose() {
    try {
      _tts.stop();
    } catch (_) {}
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _toggleMode(bool signUp) {
    setState(() {
      _isSignUp = signUp;
      _errorMessage = null;
    });
    _speak(signUp ? 'নতুন অ্যাকাউন্ট তৈরি করুন।' : 'সাইন ইন করুন।');
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (!_consentGiven) {
      setState(() {
        _errorMessage = 'চালিয়ে যেতে অনুগ্রহ করে সম্মতির বক্সে টিক দিন।';
      });
      _speak(_errorMessage!);
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    final result = _isSignUp
        ? await AuthService.signUp(
            email: _emailCtrl.text,
            password: _passwordCtrl.text,
            consentGiven: _consentGiven,
          )
        : await AuthService.signIn(
            email: _emailCtrl.text,
            password: _passwordCtrl.text,
            consentGiven: _consentGiven,
          );

    if (!mounted) return;

    if (result.success) {
      _speak(
        _isSignUp
            ? 'অ্যাকাউন্ট তৈরি সম্পন্ন। এখন AI মডেল স্বয়ংক্রিয়ভাবে ডাউনলোড হবে।'
            : 'সাইন ইন সম্পন্ন। AI মডেল প্রস্তুত করা হচ্ছে।',
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ModelDownloadPage()),
      );
      return;
    }

    setState(() {
      _busy = false;
      _errorMessage = result.error;
    });
    _speak(_errorMessage ?? 'একটি সমস্যা হয়েছে।');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 28),
                    _buildModeSwitch(),
                    const SizedBox(height: 20),
                    _buildEmailField(),
                    const SizedBox(height: 14),
                    _buildPasswordField(),
                    if (_isSignUp) ...[
                      const SizedBox(height: 14),
                      _buildConfirmField(),
                    ],
                    const SizedBox(height: 18),
                    _buildConsentCheckbox(),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 14),
                      _buildErrorBox(),
                    ],
                    const SizedBox(height: 22),
                    _buildSubmitButton(),
                    const SizedBox(height: 16),
                    Text(
                      'অ্যাকাউন্টের তথ্য শুধুমাত্র এই ফোনে সংরক্ষিত থাকে। '
                      'Hugging Face লগইনের প্রয়োজন নেই।',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Colors.indigo.shade400, Colors.indigo.shade700],
            ),
          ),
          child: const Icon(
            Icons.visibility_rounded,
            color: Colors.white,
            size: 42,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'ReWoo Vision',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          'দৃষ্টি প্রতিবন্ধী ব্যবহারকারীদের জন্য বাংলা ভয়েস সহায়ক',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildModeSwitch() {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment<bool>(
          value: true,
          label: Text('সাইন আপ', style: TextStyle(fontSize: 16)),
          icon: Icon(Icons.person_add_alt_1_rounded),
        ),
        ButtonSegment<bool>(
          value: false,
          label: Text('সাইন ইন', style: TextStyle(fontSize: 16)),
          icon: Icon(Icons.login_rounded),
        ),
      ],
      selected: {_isSignUp},
      onSelectionChanged: (selection) => _toggleMode(selection.first),
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailCtrl,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      textInputAction: TextInputAction.next,
      style: const TextStyle(fontSize: 16),
      decoration: InputDecoration(
        labelText: 'ইমেইল',
        hintText: 'name@gmail.com',
        prefixIcon: const Icon(Icons.alternate_email_rounded),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      validator: (value) {
        final error = AuthService.validateCredentials(
          value ?? '',
          '123456',
        );
        // Only surface the email-related error here (password rules are
        // validated on their own field).
        if (error != null && error.contains('ইমেইল')) return error;
        return null;
      },
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordCtrl,
      obscureText: _obscurePassword,
      autofillHints: _isSignUp
          ? const [AutofillHints.newPassword]
          : const [AutofillHints.password],
      textInputAction: _isSignUp ? TextInputAction.next : TextInputAction.done,
      style: const TextStyle(fontSize: 16),
      decoration: InputDecoration(
        labelText: 'পাসওয়ার্ড',
        helperText: _isSignUp ? 'কমপক্ষে ৬ অক্ষর' : null,
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassword ? Icons.visibility_off_rounded : Icons.visibility_rounded,
          ),
          onPressed: () =>
              setState(() => _obscurePassword = !_obscurePassword),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      validator: (value) {
        if ((value ?? '').isEmpty) return 'পাসওয়ার্ড লিখুন।';
        if (_isSignUp && (value!.length < 6)) {
          return 'পাসওয়ার্ড কমপক্ষে ৬ অক্ষরের হতে হবে।';
        }
        return null;
      },
      onFieldSubmitted: _isSignUp ? null : (_) => _submit(),
    );
  }

  Widget _buildConfirmField() {
    return TextFormField(
      controller: _confirmCtrl,
      obscureText: _obscurePassword,
      textInputAction: TextInputAction.done,
      style: const TextStyle(fontSize: 16),
      decoration: InputDecoration(
        labelText: 'পাসওয়ার্ড আবার লিখুন',
        prefixIcon: const Icon(Icons.lock_reset_rounded),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      validator: (value) {
        if (_isSignUp && value != _passwordCtrl.text) {
          return 'দুটি পাসওয়ার্ড এক নয়।';
        }
        return null;
      },
      onFieldSubmitted: (_) => _submit(),
    );
  }

  Widget _buildConsentCheckbox() {
    return Semantics(
      toggled: _consentGiven,
      label: AuthService.consentMessage,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _consentGiven
                ? Colors.green.shade300
                : Colors.grey.shade300,
          ),
        ),
        child: CheckboxListTile(
          value: _consentGiven,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeColor: Colors.indigo,
          title: Text(
            AuthService.consentMessage,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: Colors.grey.shade800,
            ),
          ),
          onChanged: (value) {
            setState(() => _consentGiven = value ?? false);
            if (_consentGiven) {
              // Soft confirmation so blind users know the tap registered.
              _speak('সম্মতি রেকর্ড হয়েছে।');
            }
          },
        ),
      ),
    );
  }

  Widget _buildErrorBox() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: Colors.red.shade700),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: Colors.red.shade700,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: _busy ? null : _submit,
        icon: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white,
                ),
              )
            : Icon(_isSignUp ? Icons.person_add_alt_rounded : Icons.login_rounded),
        label: Text(
          _busy
              ? 'অপেক্ষা করুন…'
              : (_isSignUp ? 'অ্যাকাউন্ট তৈরি করুন' : 'সাইন ইন করুন'),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
