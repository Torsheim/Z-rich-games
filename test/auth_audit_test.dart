import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zurich_games/main.dart';

import 'widget_test.dart' as helpers;

class FailedResetAuth extends helpers.FakeAuth {
  @override
  Future<void> updatePassword(String password) async {
    throw const AuthException('Network unavailable');
  }
}

void main() {
  testWidgets('reload resumes recovery after a failed password update', (
    tester,
  ) async {
    final auth = FailedResetAuth();
    await tester.pumpWidget(CityApp(service: auth));
    await helpers.tapText(tester, 'Sign in');
    await helpers.tapText(tester, 'Forgot password?');
    await helpers.enter(tester, 'Email', 'alex@example.com');
    await helpers.tapText(tester, 'Send reset code');
    await helpers.enter(tester, 'Verification code', '123456');
    await helpers.enter(tester, 'New password', 'new-valid-password');
    await helpers.enter(tester, 'Confirm password', 'new-valid-password');
    await helpers.tapText(tester, 'Save new password');
    expect(find.text('Network unavailable'), findsOneWidget);
    expect(auth.user, isNotNull);
    expect(auth.newPassword, isNull);
    await tester.pumpWidget(CityApp(key: UniqueKey(), service: auth));
    await tester.pumpAndSettle();
    expect(find.text('Your profile'), findsNothing);
    expect(find.text('Save new password'), findsOneWidget);
  });
  testWidgets(
    'registration hides passwords after leaving a revealed login field',
    (tester) async {
      await tester.pumpWidget(CityApp(service: helpers.FakeAuth()));
      await helpers.tapText(tester, 'Sign in');
      await tester.tap(find.byTooltip('Show password'));
      await helpers.tapText(tester, 'Back to welcome');
      await helpers.tapText(tester, 'Create account');
      final fields = tester.widgetList<TextFormField>(
        find.byType(TextFormField),
      );
      // A new screen must start with masked passwords.
      expect(fields.length, 4);
      expect(find.byTooltip('Show password'), findsNWidgets(2));
    },
  );
  testWidgets('delete dialog fits a mobile viewport with the keyboard open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(CityApp(service: helpers.FakeAuth()..signIn()));
    await tester.pumpAndSettle();
    await helpers.tapText(tester, 'Delete account');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
