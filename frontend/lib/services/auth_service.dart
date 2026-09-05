import 'package:supabase_flutter/supabase_flutter.dart';

/// AuthService — Supabase Auth (email + password) session owner.
///
/// Open registration = first login auto-creates the `profiles` row
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

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> init() async {
    await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
  }

  /// Email sign-up. Returns null on success, a friendly message otherwise.
  /// Note: with "Confirm email" ON (dashboard default), the user must click
  /// the inbox link before sign-in works — surfaced as email-not-confirmed.
  static Future<String?> signUpWithEmail(String email, String password, {String? username}) async {
    try {
      final res = await client.auth.signUp(
        email: email.trim(),
        password: password,
        // Claimed server-side (unique-checked); echoed back for display.
        data: username != null && username.trim().isNotEmpty ? {'username': username.trim()} : null,
      );
      // No session + identities empty = existing user re-registering; treat
      // as sign-in hint, not success (avoids account-enumeration ambiguity).
      if (res.session == null && (res.user?.identities?.isEmpty ?? true)) {
        return 'Account already exists — sign in instead.';
      }
      return null;
    } on AuthException catch (e) {
      return _friendlyEmailError(e);
    } catch (_) {
      return 'Sign-up failed — check your connection and retry.';
    }
  }

  /// Email sign-in. Returns null on success, a friendly message otherwise.
  static Future<String?> signInWithEmail(String email, String password) async {
    try {
      await client.auth.signInWithPassword(email: email.trim(), password: password);
      return null;
    } on AuthException catch (e) {
      return _friendlyEmailError(e);
    } catch (_) {
      return 'Sign-in failed — check your connection and retry.';
    }
  }

  static String _friendlyEmailError(AuthException e) {
    final code = (e.code ?? '').toLowerCase();
    if (code == 'invalid_credentials' || code == 'invalid_login_credentials') {
      return 'Wrong email or password.';
    }
    if (code == 'email_not_confirmed') {
      return 'Check your inbox for the confirmation link, then sign in.';
    }
    if (code == 'user_already_exists' || code.contains('already')) {
      return 'Account already exists — sign in instead.';
    }
    if (code == 'weak_password') {
      return 'Password too weak — use at least 6 characters.';
    }
    if (code == 'validation_failed') {
      return 'Enter a valid email address.';
    }
    if (code == 'signup_disabled') {
      return 'Registrations are disabled — ask the admin to enable them.';
    }
    if (code.contains('rate_limit') ||
        code.contains('too_many') ||
        code == 'over_request_rate_limit' ||
        e.message.contains('after ') && e.message.contains('seconds')) {
      // Supabase throttles repeated signup attempts (observed: "you can only
      // request this after N seconds"). Back off instead of retrying fast.
      return 'Too many attempts — wait a minute, then try signing in.';
    }
    // Include the raw code so bug reports are actionable instead of generic.
    return 'Authentication failed ($code) — please retry.';
  }

  static Future<void> signOut() => client.auth.signOut();

  /// Username rules, mirrored server-side (server re-validates, never trusts).
  static bool validUsername(String name) =>
      RegExp(r'^[a-zA-Z0-9_]{2,24}$').hasMatch(name.trim());

  /// Availability probe for the signup form. Reads the anon-readable
  /// profiles (no session yet) — the server still re-checks at claim time
  /// to close the race. Returns null when unavailable/unknown (fail open:
  /// signup surfaces the authoritative error).
  static Future<bool?> checkUsernameAvailable(String name) async {
    final clean = name.trim();
    if (!validUsername(clean)) return false;
    try {
      final rows = await client
          .from('profiles')
          .select('user_id')
          .ilike('username', clean)
          .limit(1);
      return (rows as List).isEmpty;
    } catch (_) {
      return null;
    }
  }

  /// Best display name: chosen username → full name → email handle.
  static String displayName(User user) {
    final meta = user.userMetadata ?? const <String, dynamic>{};
    final chosen = ((meta['username'] ?? '') as String).trim();
    if (validUsername(chosen)) return chosen;
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
