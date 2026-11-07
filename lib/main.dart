import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_service.dart';
import 'auth/auth_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  AuthService? service;
  String? setupError;
  if (url.isNotEmpty && key.isNotEmpty) {
    try {
      await Supabase.initialize(url: url, publishableKey: key);
      service = SupabaseAuthService(
        Supabase.instance.client,
        await SharedPreferences.getInstance(),
      );
    } catch (_) {
      setupError = 'Unable to initialize the connection. Check your configuration and restart the app.';
    }
  }
  runApp(CityApp(service: service, setupError: setupError));
}

class CityApp extends StatelessWidget {
  const CityApp({super.key, this.service, this.setupError});
  final AuthService? service;
  final String? setupError;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'City Together',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF196C5D)),
      scaffoldBackgroundColor: const Color(0xFFF5F7F5),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      ),
    ),
    home: service == null
        ? Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.settings_outlined, size: 48),
                      const SizedBox(height: 24),
                      const Text(
                        'Connect your backend',
                        style: TextStyle(fontSize: 26),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        setupError ?? 'Add your Supabase configuration to start. See README.md for setup instructions.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        : AuthScreen(service: service!),
  );
}
