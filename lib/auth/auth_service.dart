import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class AuthService {
  Stream<void> get changes;
  String? get recoveryEmail;
  User? get user;
  Future<void> register(String username, String email, String password);
  Future<void> login(String email, String password);
  Future<void> verify(String email, String code, {bool recovery = false});
  Future<void> resend(String email);
  Future<void> requestReset(String email);
  Future<void> updatePassword(String password);
  Future<void> logout();
  Future<Map<String, dynamic>> profile();
  Future<void> deleteAccount(String password);
}

class SupabaseAuthService implements AuthService {
  SupabaseAuthService(this.client, this.preferences);
  final SharedPreferences preferences;
  String get _recoveryKey => 'city_pending_recovery_${client.rest.url}';
  @override
  String? get recoveryEmail => preferences.getString(_recoveryKey);
  final SupabaseClient client;
  @override
  Stream<void> get changes => client.auth.onAuthStateChange.map((_) {});
  @override
  User? get user => client.auth.currentUser;
  @override
  Future<void> register(String username, String email, String password) async {
    await client.auth.signUp(
      email: email,
      password: password,
      data: {'username': username},
    );
  }

  @override
  Future<void> login(String email, String password) async {
    await client.auth.signInWithPassword(email: email, password: password);
  }

  @override
  Future<void> verify(
    String email,
    String code, {
    bool recovery = false,
  }) async {
    await client.auth.verifyOTP(
      email: email,
      token: code,
      type: recovery ? OtpType.recovery : OtpType.signup,
    );
  }

  @override
  Future<void> resend(String email) async {
    await client.auth.resend(type: OtpType.signup, email: email);
  }

  @override
  Future<void> requestReset(String email) async {
    await client.auth.resetPasswordForEmail(email);
    await preferences.setString(_recoveryKey, email);
  }

  @override
  Future<void> updatePassword(String password) async {
    await client.auth.updateUser(UserAttributes(password: password));
    await preferences.remove(_recoveryKey);
  }

  @override
  Future<void> logout() async {
    await client.auth.signOut();
    await preferences.remove(_recoveryKey);
  }

  @override
  Future<Map<String, dynamic>> profile() =>
      client.from('profiles').select().eq('id', user!.id).single();
  @override
  Future<void> deleteAccount(String password) async {
    final result = await client.functions.invoke(
      'delete-account',
      body: {'password': password},
    );
    if (result.status != 200) {
      throw const AuthException(
        'Unable to delete your account. Please try again.',
      );
    }
    await client.auth.signOut(scope: SignOutScope.local);
  }
}

String? validateUsername(String? value) =>
    RegExp(r'^[a-zA-Z0-9_]{3,24}$').hasMatch(value?.trim() ?? '')
    ? null
    : 'Use 3–24 letters, numbers or underscores.';
String? validateEmail(String? value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '')
    ? null
    : 'Enter a valid email address.';
String? validatePassword(String? value) =>
    (value?.length ?? 0) >= 12 ? null : 'Use at least 12 characters.';
