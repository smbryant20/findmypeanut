class Env {
  static const supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const supabaseAnon =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
  static const funUrl =
      String.fromEnvironment('SUPABASE_FUN_URL', defaultValue: '');

  static void assertReady() {
    assert(supabaseUrl.isNotEmpty && supabaseAnon.isNotEmpty,
        'Missing SUPABASE_URL/SUPABASE_ANON_KEY. Use --dart-define or dart_defines.json');
  }
}
