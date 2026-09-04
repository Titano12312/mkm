import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// AuthService — Supabase Auth (Google) session owner.
///
/// FLOW (identical on Android + Windows): the system browser opens Google
/// via Supabase → redirect `com.tellaviv.app://login-callback` → the OS
/// routes it back (Android intent-filter / Windows registry protocol) →
/// app_links delivers the URI → session recovered. No passwords anywhere.
///
/// Open registration = first Google login auto-creates the `profiles` row
/// server-side (see backend verifyToken). No invite codes, no admin step.
class AuthService {
  AuthService._();

  // Publishable values (safe to bake in): the anon key is public by design,
  // RLS policies are what protect the data. Overridable at build time.
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://sxedufnjjijgsohelvys.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_2lkYm7-yvzRQ55lkqa7c7g_oa3GYCW_',
  );
  static const oauthRedirect = 'com.tellaviv.app://login-callback';

  static final _appLinks = AppLinks();
  // Held (never cancelled) so the OS deep-link stream stays alive for the
  // whole app lifetime — OAuth callbacks can arrive at any moment.
  // ignore: unused_field
  static StreamSubscription<Uri>? _linkSub;
  static bool _listening = false;

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> init() async {
    await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
    // Cold start: the app itself was opened by the OAuth redirect already
    // carrying the session (typical on Windows protocol launch).
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) await _recover(initial);
    } catch (e) {
      if (kDebugMode) print('auth initial link: $e');
    }
    if (!_listening) {
      _listening = true;
      _linkSub = _appLinks.uriLinkStream.listen(
        _recover,
        onError: (Object e) {
          if (kDebugMode) print('auth link stream: $e');
        },
      );
    }
  }

  static Future<void> _recover(Uri uri) async {
    // Only our OAuth callback; ignore every other deep link.
    if (uri.scheme != 'com.tellaviv.app') return;
    try {
      await client.auth.getSessionFromUrl(uri);
    } catch (e) {
      if (kDebugMode) print('auth recover session: $e');
    }
  }

  static Future<void> signInWithGoogle() {
    return client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: oauthRedirect,
      authScreenLaunchMode: LaunchMode.externalApplication,
    );
  }

  static Future<void> signOut() => client.auth.signOut();

  /// Best display name: Google full name → email handle → fallback.
  static String displayName(User user) {
    final meta = user.userMetadata ?? const <String, dynamic>{};
    final full = ((meta['full_name'] ?? meta['name'] ?? '') as String).trim();
    if (full.isNotEmpty) return full.substring(0, full.length > 32 ? 32 : full.length);
    final email = user.email ?? '';
    if (email.contains('@')) {
      final handle = email.split('@').first;
      return handle.substring(0, handle.length > 32 ? 32 : handle.length);
    }
    return 'Friend';
  }
}
