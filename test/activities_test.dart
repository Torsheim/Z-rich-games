import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zurich_games/activities/create_activity_screen.dart';

import 'friends_test.dart' as friendship;

import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:zurich_games/activities/activity.dart';
import 'package:zurich_games/activities/activity_service.dart';
import 'package:zurich_games/activities/app_shell.dart';
import 'package:zurich_games/main.dart';

import 'widget_test.dart' as helpers;

class FakeActivities extends ActivityService {
  FakeActivities()
    : super(
        SupabaseClient(
          'http://localhost:54321',
          'public-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  final List<Activity> rows = [];
  int creates = 0, responses = 0, publishes = 0;
  Completer<String>? pendingResponse;
  bool responseFails = false;
  List<String> invited = [];
  @override
  RealtimeChannel? watch(VoidCallback changed) => null;
  @override
  Future<List<Activity>> feed() async => rows;
  @override
  Future<String> create(
    Map<String, dynamic> details,
    List<String> friends,
  ) async {
    creates++;
    invited = friends;
    rows.add(
      Activity({
        ...details,
        'id': 'new-activity',
        'created_by_user_id': 'test-id',
        'host_username': 'alex',
        'participant_count': 1,
        'my_status': 'confirmed',
        'invite_status': null,
      }),
    );
    return 'new-activity';
  }

  @override
  Future<String> respond(String id, String response) async {
    responses++;
    if (responseFails) throw Exception('offline');
    final result = pendingResponse == null
        ? (response == 'decline' ? 'cancelled' : 'confirmed')
        : await pendingResponse!.future;
    final index = rows.indexWhere((a) => a.id == id);
    if (index >= 0) {
      rows[index] = rows[index].withData({
        'my_status': result,
        'invite_status': response == 'decline' ? 'declined' : 'accepted',
      });
    }
    return result;
  }

  @override
  Future<void> publish(String id, String visibility, String policy) async {
    publishes++;
  }
}

Widget shell(FakeActivities activities) => MaterialApp(
  home: AppShell(
    userId: 'test-id',
    username: 'alex',
    profile: const Center(child: Text('Profile content')),
    activities: activities,
  ),
);
Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text).last;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('en');
  });
  testWidgets(
    'Home focuses on invitations and confirmed plans; public plans live in Search',
    (tester) async {
      final service = FakeActivities();
      await tester.pumpWidget(shell(service));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDestination), findsNWidgets(4));
      expect(find.text('An evening at the Kunsthaus'), findsOneWidget);
      expect(find.text('Friday bowling crew'), findsOneWidget);
      expect(find.text('Lakeside walk & a coffee'), findsOneWidget);
      expect(find.text('A table for a few more'), findsOneWidget);
      expect(find.text('Darts, drinks & new faces'), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      await tapText(tester, 'An evening at the Kunsthaus');
      expect(find.text('Heimplatz 1, Zurich'), findsOneWidget);
      await tapText(tester, 'I’m going');
      expect(find.text('Going'), findsOneWidget);
      expect(
        service.responses,
        0,
        reason: 'Examples must not write to the backend.',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapText(tester, 'Search');
      expect(find.text('Around you'), findsOneWidget);
      expect(find.text('Darts, drinks & new faces'), findsOneWidget);
      await tapText(tester, 'Profile');
      expect(find.text('Profile content'), findsOneWidget);
    },
  );
  testWidgets(
    'Welcome, direct invitation actions and a single prominent next plan',
    (tester) async {
      final service = FakeActivities();
      await tester.pumpWidget(shell(service));
      await tester.pumpAndSettle();
      expect(find.text('Hello, alex.'), findsOneWidget);
      expect(find.byKey(const ValueKey('next-example-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-example-3')), findsNothing);
      final card = find.byKey(const ValueKey('invite-example-1'));
      final accept = find.descendant(
        of: card,
        matching: find.widgetWithText(FilledButton, 'Accept'),
      );
      await tester.ensureVisible(accept);
      await tester.pumpAndSettle();
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('invite-example-1')), findsNothing);
      expect(find.byKey(const ValueKey('next-example-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-example-3')), findsOneWidget);
      expect(
        find.text('Example activity'),
        findsNothing,
        reason: 'Direct replies stay on Home.',
      );
      final full = find.byKey(const ValueKey('invite-example-2'));
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: full,
                matching: find.widgetWithText(FilledButton, 'Accept'),
              ),
            )
            .onPressed,
        isNull,
      );
      final decline = find.descendant(
        of: full,
        matching: find.widgetWithText(OutlinedButton, 'Decline'),
      );
      await tester.ensureVisible(decline);
      await tester.pumpAndSettle();
      await tester.tap(decline);
      await tester.pumpAndSettle();
      expect(find.textContaining('Declined'), findsOneWidget);
      expect(service.responses, 0);
    },
  );
  testWidgets(
    'Direct replies prevent double submission and can recover from a failure',
    (tester) async {
      final service = FakeActivities();
      service.rows.add(
        Activity({
          ...exampleActivities('test-id').first.data,
          'id': 'real-invite',
          'demo': false,
          'title': 'A real invitation',
        }),
      );
      service.responseFails = true;
      await tester.pumpWidget(shell(service));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('invite-real-invite'));
      var accept = find.descendant(
        of: card,
        matching: find.widgetWithText(FilledButton, 'Accept'),
      );
      await tester.ensureVisible(accept);
      await tester.pumpAndSettle();
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(service.responses, 1);
      expect(
        find.textContaining('Could not save your response.'),
        findsOneWidget,
      );
      service.responseFails = false;
      service.pendingResponse = Completer<String>();
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(service.responses, 2);
      expect(tester.widget<FilledButton>(accept).onPressed, isNull);
      final decline = find.descendant(
        of: card,
        matching: find.widgetWithText(OutlinedButton, 'Decline'),
      );
      expect(tester.widget<OutlinedButton>(decline).onPressed, isNull);
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(service.responses, 2);
      service.pendingResponse!.complete('confirmed');
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      expect(
        find.textContaining('Could not save your response.'),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('next-real-invite')), findsOneWidget);
    },
  );
  testWidgets(
    'Next plan is the earliest future confirmation; the rest remain chronological',
    (tester) async {
      final service = FakeActivities();
      final base = exampleActivities('test-id')[2];
      for (final item in [
        ('late', 3),
        ('early', 1),
        ('middle', 2),
        ('past', -1),
      ]) {
        service.rows.add(
          base.withData({
            'id': item.$1,
            'title': 'Plan ${item.$1}',
            'demo': false,
            'starts_at': DateTime.now()
                .add(Duration(hours: item.$2))
                .toUtc()
                .toIso8601String(),
          }),
        );
      }
      await tester.pumpWidget(shell(service));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('next-early')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-early')), findsNothing);
      expect(find.text('Plan past'), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('plan-middle'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('plan-late'))).dy),
      );
    },
  );
  testWidgets('Full invitations cannot be accepted but can be declined', (
    tester,
  ) async {
    await tester.pumpWidget(shell(FakeActivities()));
    await tester.pumpAndSettle();
    await tapText(tester, 'Friday bowling crew');
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Currently full'),
    );
    expect(button.onPressed, isNull);
    await tapText(tester, 'Decline invitation');
    expect(find.text('Not going'), findsOneWidget);
  });
  testWidgets('A private example can be published without losing its group', (
    tester,
  ) async {
    final service = FakeActivities();
    await tester.pumpWidget(shell(service));
    await tester.pumpAndSettle();
    await tapText(tester, 'A table for a few more');
    await tapText(tester, 'Publish publicly');
    await tapText(tester, 'Publish activity');
    expect(find.text('Public'), findsOneWidget);
    expect(find.text('3 of 6 places taken'), findsOneWidget);
    expect(service.publishes, 0);
  });
  testWidgets('Creating a personal plan validates fields and adds it to Home', (
    tester,
  ) async {
    final service = FakeActivities();
    await tester.pumpWidget(shell(service));
    await tester.pumpAndSettle();
    await tapText(tester, 'Create');
    await tapText(tester, 'Create activity');
    expect(service.creates, 0);
    await tester.ensureVisible(
      find.widgetWithText(TextFormField, 'Activity title'),
    );
    await helpers.enter(tester, 'Activity title', 'Dinner with friends');
    expect(find.widgetWithText(TextFormField, 'Description'), findsNothing);
    expect(
      find.widgetWithText(TextFormField, 'Maximum participants'),
      findsNothing,
    );
    await tester.ensureVisible(
      find.widgetWithText(TextFormField, 'Meeting point'),
    );
    await helpers.enter(tester, 'Meeting point', 'The main entrance');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tapText(tester, 'Create activity');
    expect(service.creates, 1);
    expect(service.rows.single.data['kind'], 'activity');
    expect(service.rows.single.visibility, 'invite_only');
    expect(service.rows.single.policy, 'invitation_required');
    expect(service.rows.single.limit, isNull);
    expect(find.text('Dinner with friends'), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
  });
  testWidgets(
    'Create refreshes newly added friends and sends only selected IDs',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final friends = friendship.FakeFriends(
        SupabaseClient(
          'http://localhost:54321',
          'public-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
        await SharedPreferences.getInstance(),
      );
      addTearDown(friends.dispose);
      List<String>? selected;
      Future<void> create(
        Map<String, dynamic> data,
        List<String> invited,
      ) async {
        selected = invited;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreateActivityScreen(friends: friends, onCreate: create),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Invite friends');
      expect(find.textContaining('No friends yet.'), findsOneWidget);
      await tapText(tester, 'Cancel');
      friends.accepts = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreateActivityScreen(
              friends: friends,
              onCreate: create,
              revision: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Invite friends');
      await tapText(tester, 'sam');
      await tapText(tester, 'Done');
      await tester.ensureVisible(
        find.widgetWithText(TextFormField, 'Activity title'),
      );
      await tester.pumpAndSettle();
      await helpers.enter(tester, 'Activity title', 'A friendly plan');
      await tester.ensureVisible(
        find.widgetWithText(TextFormField, 'Meeting point'),
      );
      await tester.pumpAndSettle();
      await helpers.enter(tester, 'Meeting point', 'The meeting point');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tapText(tester, 'Create activity');
      expect(selected, ['sam-id']);
    },
  );
  testWidgets(
    'More options expands on demand and preserves advanced settings when collapsed',
    (tester) async {
      final service = FakeActivities();
      await tester.pumpWidget(shell(service));
      await tester.pumpAndSettle();
      await tapText(tester, 'Create');
      expect(find.widgetWithText(TextFormField, 'Description'), findsNothing);
      await helpers.enter(tester, 'Activity title', 'A simple dinner');
      await helpers.enter(tester, 'Meeting point', 'The usual spot');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tapText(tester, 'More options');
      await tester.ensureVisible(
        find.widgetWithText(TextFormField, 'Description'),
      );
      await tester.pumpAndSettle();
      await helpers.enter(tester, 'Description', 'Bring something to share.');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final unlimited = find.widgetWithText(
        SwitchListTile,
        'No participant limit',
      );
      await tester.ensureVisible(unlimited);
      await tester.pumpAndSettle();
      await tester.tap(unlimited);
      await tester.pumpAndSettle();
      await helpers.enter(tester, 'Maximum participants', '0');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tapText(tester, 'More options');
      expect(find.widgetWithText(TextFormField, 'Description'), findsNothing);
      await tapText(tester, 'Create activity');
      expect(service.creates, 0);
      expect(
        find.text('Enter a whole number from 1 to 10,000.'),
        findsOneWidget,
      );
      await helpers.enter(tester, 'Maximum participants', '4');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tapText(tester, 'More options');
      await tapText(tester, 'Create activity');
      expect(service.rows.single.limit, 4);
      expect(
        service.rows.single.data['description'],
        'Bring something to share.',
      );
    },
  );
  testWidgets(
    'A declined invitation stays accessible for changing the response',
    (tester) async {
      await tester.pumpWidget(shell(FakeActivities()));
      await tester.pumpAndSettle();
      await tapText(tester, 'An evening at the Kunsthaus');
      await tapText(tester, 'Decline invitation');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapText(tester, 'An evening at the Kunsthaus');
      expect(find.text('Change to going'), findsOneWidget);
    },
  );
  testWidgets('Signed-in app opens Home, retains Profile and can sign out', (
    tester,
  ) async {
    final auth = helpers.FakeAuth()..signIn();
    await tester.pumpWidget(
      CityApp(service: auth, activities: FakeActivities()),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    await tapText(tester, 'Profile');
    expect(find.text('Your profile'), findsOneWidget);
    await tapText(tester, 'Sign out');
    expect(find.text('Your city. Your people.'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
  testWidgets('Home layout fits a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(shell(FakeActivities()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
