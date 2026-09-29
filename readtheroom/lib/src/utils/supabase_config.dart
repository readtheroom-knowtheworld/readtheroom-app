// Supabase connection settings, supplied at build time only.
//
// There is deliberately no compiled-in fallback: a build without these
// defines must fail loudly rather than quietly talk to someone else's
// backend. Pass them with `--dart-define-from-file=.env` (see `.env.example`
// at the repository root) or individual `--dart-define` flags.

class SupabaseConfig {
  SupabaseConfig._();

  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// Throws a [StateError] naming the missing defines when the build was
  /// made without them.
  static void ensureConfigured() {
    if (isConfigured) return;
    final missing = [
      if (url.isEmpty) 'SUPABASE_URL',
      if (anonKey.isEmpty) 'SUPABASE_ANON_KEY',
    ].join(', ');
    throw StateError(
      'Missing build-time configuration: $missing. '
      'Copy .env.example to .env, fill in your own Supabase project, and '
      'build with --dart-define-from-file=.env.',
    );
  }
}
