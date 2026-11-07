import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zurich_games/auth/auth_service.dart';
import 'package:zurich_games/main.dart';

class FakeAuth implements AuthService {
  User? current;
  bool registered = false;
  String? verifiedCode;
  bool deleted = false;
  bool resetRequested = false;
  String? newPassword;
  @override
  User? get user => current;
  @override
  Stream<void> get changes => const Stream.empty();
  void signIn() => current = User(
    id: 'test-id',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-11-07T10:00:00Z',
    email: 'alex@example.com',
    emailConfirmedAt: '2026-11-07T10:00:00Z',
  );
  @override
  Future<void> register(String username, String email, String password) async {
    registered = true;
  }

  @override
  Future<void> login(String email, String password) async {
    signIn();
  }

  @override
  Future<void> verify(
    String email,
    String code, {
    bool recovery = false,
  }) async {
    if (code != '123456') {
      throw const AuthException('Invalid verification code.');
    }
    verifiedCode = code;
    signIn();
  }

  @override
  Future<void> resend(String email) async {}
  @override
  Future<void> requestReset(String email) async {
    resetRequested = true;
  }

  @override
  Future<void> updatePassword(String password) async {
    newPassword = password;
  }

  @override
  Future<void> logout() async {
    current = null;
  }

  @override
  Future<Map<String, dynamic>> profile() async => {
    'username': 'alex',
    'created_at': '2026-11-07T10:00:00Z',
  };
  @override
  Future<void> deleteAccount(String password) async {
    if (password != 'valid-password') {
      throw const AuthException('Incorrect password.');
    }
    deleted = true;
    current = null;
  }
}

Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text).last;
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String label, String value) async {
  await tester.enterText(find.widgetWithText(TextFormField, label), value);
}

void main() {
  test('Registration validators reject invalid input', () {
    expect(validateUsername('ab'), isNotNull);
    expect(validateUsername('alex_123'), isNull);
    expect(validateUsername('alex name'), isNotNull);
    expect(validateEmail('broken@'), isNotNull);
    expect(validateEmail('alex@example.com'), isNull);
    expect(validatePassword('short'), isNotNull);
    expect(validatePassword('valid-password'), isNull);
  });

  testWidgets('Missing backend shows setup instead of fake login', (
    tester,
  ) async {
    await tester.pumpWidget(const CityApp());
    expect(find.text('Connect your backend'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
  });

  testWidgets('Registration requires valid data and email verification', (
    tester,
  ) async {
    final auth = FakeAuth();
    await tester.pumpWidget(CityApp(service: auth));
    await tapText(tester, 'Create account');
    await tapText(tester, 'Create account');
    expect(auth.registered, isFalse);
    await enter(tester, 'Username', 'alex');
    await enter(tester, 'Email', 'alex@example.com');
    await enter(tester, 'Password', 'valid-password');
    await enter(tester, 'Confirm password', 'valid-password');
    await tapText(tester, 'Create account');
    expect(auth.registered, isTrue);
    expect(find.text('Check your email'), findsOneWidget);
    expect(auth.user, isNull);
    await enter(tester, 'Verification code', '000000');
    await tapText(tester, 'Verify email');
    expect(find.text('Invalid verification code.'), findsOneWidget);
    await enter(tester, 'Verification code', '123456');
    await tapText(tester, 'Verify email');
    expect(find.text('Your profile'), findsOneWidget);
    expect(find.text('alex'), findsOneWidget);
    await tapText(tester, 'Sign out');
    expect(find.text('Your city. Your people.'), findsOneWidget);
  });

  testWidgets('Password reset verifies a code before updating password', (
    tester,
  ) async {
    final auth = FakeAuth();
    await tester.pumpWidget(CityApp(service: auth));
    await tapText(tester, 'Sign in');
    await tapText(tester, 'Forgot password?');
    await enter(tester, 'Email', 'alex@example.com');
    await tapText(tester, 'Send reset code');
    expect(auth.resetRequested, isTrue);
    await enter(tester, 'Verification code', '123456');
    await enter(tester, 'New password', 'new-valid-password');
    await enter(tester, 'Confirm password', 'new-valid-password');
    await tapText(tester, 'Save new password');
    expect(auth.verifiedCode, '123456');
    expect(auth.newPassword, 'new-valid-password');
    expect(find.text('Your profile'), findsOneWidget);
  });

  testWidgets('Deletion requires confirmation and correct password', (
    tester,
  ) async {
    final auth = FakeAuth()..signIn();
    await tester.pumpWidget(CityApp(service: auth));
    await tester.pumpAndSettle();
    await tapText(tester, 'Delete account');
    await tapText(tester, 'Cancel');
    expect(auth.deleted, isFalse);
    await tapText(tester, 'Delete account');
    await tester.enterText(find.byType(TextField), 'wrong-password');
    await tapText(tester, 'Delete permanently');
    expect(auth.deleted, isFalse);
    expect(find.text('Incorrect password.'), findsOneWidget);
    await tapText(tester, 'Delete account');
    await tester.enterText(find.byType(TextField), 'valid-password');
    await tapText(tester, 'Delete permanently');
    expect(auth.deleted, isTrue);
    expect(find.text('Your city. Your people.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });
}
