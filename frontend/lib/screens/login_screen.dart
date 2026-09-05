import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/motion.dart';
import '../services/auth_service.dart';

/// Login screen — email + password, open registration for friends.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  bool _signupMode = false;
  String? _error;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _username = TextEditingController();

  Future<void> _submitEmail() async {
    final email = _email.text.trim();
    final username = _username.text.trim();
    if (!email.contains('@') || _password.text.length < 6) {
      setState(() => _error = 'Enter a valid email and a 6+ character password.');
      return;
    }
    if (_signupMode && !AuthService.validUsername(username)) {
      setState(() => _error = 'Username: 2–24 letters, numbers or underscores.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signupMode) {
        // Fail fast on taken names (server re-checks at claim time anyway).
        final free = await AuthService.checkUsernameAvailable(username);
        if (free == false) {
          if (mounted) {
            setState(() {
              _error = 'That username is taken — try another.';
              _busy = false;
            });
          }
          return;
        }
      }
      final err = _signupMode
          ? await AuthService.signUpWithEmail(email, _password.text, username: username)
          : await AuthService.signInWithEmail(email, _password.text);
      // Success needs no navigation: the auth-state stream flips and
      // AuthGate swaps to the chat shell by itself.
      if (err != null && mounted) setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _username.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = Motion.reduce(context);
    final logo = ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Image.asset(
        'assets/logo.png',
        width: 84,
        height: 84,
        fit: BoxFit.cover,
      ),
    );
    return Scaffold(
      backgroundColor: const Color(0xFF1E1F22),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  reduce
                      ? logo
                      : logo
                          .animate()
                          .scale(
                            // Confident arrival from an already-visible
                            // default — never elastic on a form surface.
                            // Operate mode: don't make sign-in wait.
                            begin: const Offset(0.85, 0.85),
                            end: const Offset(1, 1),
                            duration: Motion.enter,
                            curve: Motion.standard,
                          )
                          .fadeIn(duration: Motion.fast),
                  const SizedBox(height: 24),
                  _Stagger(
                    delay: 0,
                    reduce: reduce,
                    child: const Text('TellAviv',
                        style: TextStyle(
                            color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 8),
                  _Stagger(
                    delay: 1,
                    reduce: reduce,
                    child: const Text('Your private corner — sign in to join your friends.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 14)),
                  ),
                  const SizedBox(height: 24),
                  _Stagger(
                    delay: 2,
                    reduce: reduce,
                    child: _ModeToggle(
                      signup: _signupMode,
                      onChanged: (v) => setState(() {
                        _signupMode = v;
                        _error = null;
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Stagger(
                    delay: 3,
                    reduce: reduce,
                    child: _DarkField(
                      controller: _email,
                      hint: 'Email',
                      keyboard: TextInputType.emailAddress,
                      onSubmitted: (_) => _submitEmail(),
                    ),
                  ),
                  if (_signupMode) ...[
                    const SizedBox(height: 10),
                    _Stagger(
                      delay: 3,
                      reduce: reduce,
                      child: _DarkField(
                        controller: _username,
                        hint: 'Choose a username',
                        onSubmitted: (_) => _submitEmail(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  _Stagger(
                    delay: 4,
                    reduce: reduce,
                    child: _DarkField(
                      controller: _password,
                      hint: 'Password (6+ characters)',
                      obscure: true,
                      onSubmitted: (_) => _submitEmail(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _Stagger(
                    delay: 5,
                    reduce: reduce,
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _submitEmail,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF5757),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Text(_signupMode ? 'Create account' : 'Sign in',
                                style: const TextStyle(fontSize: 15)),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final bool signup;
  final ValueChanged<bool> onChanged;
  const _ModeToggle({required this.signup, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final mode in [false, true])
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(mode),
                child: AnimatedContainer(
                  duration: Motion.base,
                  curve: Motion.standard,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: signup == mode ? const Color(0xFF404249) : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    mode ? 'Create account' : 'Sign in',
                    style: TextStyle(
                      color: signup == mode ? Colors.white : Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DarkField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final TextInputType keyboard;
  final ValueChanged<String> onSubmitted;
  const _DarkField({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.keyboard = TextInputType.text,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
        filled: true,
        fillColor: const Color(0xFF2B2D31),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      onSubmitted: onSubmitted,
    );
  }
}

/// Staggered rise used by the login entrance (skipped under reduced motion).
/// Total delay capped at ~400ms so sign-in never waits on choreography.
class _Stagger extends StatelessWidget {
  final int delay;
  final bool reduce;
  final Widget child;
  const _Stagger({required this.delay, required this.reduce, required this.child});

  @override
  Widget build(BuildContext context) {
    if (reduce) return child;
    final step = Duration(milliseconds: 80 * delay);
    return child.animate().fadeIn(duration: Motion.fast, delay: step).slideY(
          begin: 0.25,
          end: 0,
          duration: Motion.enter,
          delay: step,
          curve: Motion.standard,
        );
  }
}
