import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/motion.dart';
import '../services/auth_service.dart';

/// Login screen — Google only (open registration for the friends group).
/// Motion: elastic logo drop, staggered rise of title/subtitle/button.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Opens the system browser; control returns here immediately while
      // the user completes Google login. Success arrives via the auth
      // state stream (AuthGate navigates), not via this future.
      await AuthService.signInWithGoogle();
    } catch (e) {
      setState(() => _error = 'Login did not finish — check your connection and retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = Motion.reduce(context);
    final logo = Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: const Color(0xFF5865F2),
        borderRadius: BorderRadius.circular(24),
      ),
      alignment: Alignment.center,
      child: const Text('T',
          style: TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.bold)),
    );
    return Scaffold(
      backgroundColor: const Color(0xFF1E1F22),
      body: Center(
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
                          begin: const Offset(0.3, 0.3),
                          end: const Offset(1, 1),
                          duration: Motion.playful,
                          curve: Motion.spring,
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
                const SizedBox(height: 32),
                _Stagger(
                  delay: 2,
                  reduce: reduce,
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _login,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('G',
                                    style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF4285F4))),
                                SizedBox(width: 12),
                                Text('Continue with Google', style: TextStyle(fontSize: 15)),
                              ],
                            ),
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
    );
  }
}

/// Staggered rise used by the login entrance (skipped under reduced motion).
class _Stagger extends StatelessWidget {
  final int delay;
  final bool reduce;
  final Widget child;
  const _Stagger({required this.delay, required this.reduce, required this.child});

  @override
  Widget build(BuildContext context) {
    if (reduce) return child;
    return child.animate().fadeIn(duration: Motion.fast, delay: Duration(milliseconds: 120 * delay)).slideY(
          begin: 0.4,
          end: 0,
          duration: Motion.enter,
          delay: Duration(milliseconds: 120 * delay),
          curve: Motion.entrance,
        );
  }
}
