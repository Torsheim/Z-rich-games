import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_service.dart';
import 'auth/auth_screen.dart';
import 'friends/friend_service.dart';
import 'activities/activity_service.dart';

import 'package:timezone/data/latest.dart' as timezone;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone.initializeTimeZones();
  await initializeDateFormatting('en');
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  AuthService? service;
  String? setupError;
  FriendService? friends;
  ActivityService? activities;
  if (url.isNotEmpty && key.isNotEmpty) {
    try {
      await Supabase.initialize(url: url, publishableKey: key);
      const publicUrl = String.fromEnvironment('APP_PUBLIC_URL');
      final base = publicUrl.isNotEmpty
          ? Uri.parse(publicUrl)
          : Uri.base.scheme.startsWith('http')
          ? Uri.base.replace(query: '', fragment: '')
          : Uri.parse('citytogether://friend');
      friends = FriendService(
        Supabase.instance.client,
        await SharedPreferences.getInstance(),
        base,
      );
      await friends.initialize();
      activities = ActivityService(Supabase.instance.client);
      service = SupabaseAuthService(
        Supabase.instance.client,
        await SharedPreferences.getInstance(),
      );
    } catch (_) {
      setupError = 'Unable to initialize the connection. Check your configuration and restart the app.';
    }
  }
  runApp(
    CityApp(
      service: service,
      setupError: setupError,
      friends: friends,
      activities: activities,
    ),
  );
}

class CityApp extends StatelessWidget {
  const CityApp({
    super.key,
    this.service,
    this.setupError,
    this.friends,
    this.activities,
  });
  final AuthService? service;
  final FriendService? friends;
  final ActivityService? activities;
  final String? setupError;
  @override
  Widget build(BuildContext context) => MaterialApp(
    initialRoute: '/',
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
        : AuthScreen(
            service: service!,
            friends: friends,
            activities: activities,
          ),
  );
}
