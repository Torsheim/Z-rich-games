import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:zurich_games/events/event_service.dart';
import 'package:zurich_games/events/events_screen.dart';

const eventId = '3fce16ca-5c0f-419f-b803-7e2ae0f8e0c5';
const eventTitle = 'Community rowing';
const updateId = 'rowing-time-changed';

class _FakeEvents implements EventService {
  final startsAt = DateTime.now().toUtc().add(const Duration(days: 1));
  final changes = <String>[];
  String? participation;
  String? cityFilter;
  bool read = false;

  EventActivity get event => EventActivity({
    'id': eventId,
    'title': eventTitle,
    'organizer_id': 'club',
    'organizer_name': 'Lakeside Club',
    'city_id': 'zurich',
    'city_name': 'Zurich',
    'category_id': 'sports',
    'category_name': 'Sports',
    'starts_at': startsAt.toIso8601String(),
    'timezone': 'Europe/Zurich',
    'place_name': 'Rowing clubhouse',
    'address': 'Seestrasse 12',
    'status': 'active',
    'visibility': 'public',
    'join_policy': 'instant',
    'max_participants': 3,
    'available_places': participation == 'confirmed' ? 2 : 3,
  });

  @override
  Future<EventCatalog> catalog() async => const EventCatalog(
    cities: [EventCity('zurich', 'Zurich', 'zurich', 'Europe/Zurich')],
    categories: [EventCategory('sports', 'Sports', 'sports')],
  );

  @override
  Future<List<EventActivity>> listEvents({
    String? cityId,
    String? categoryId,
    EventActivity? after,
  }) async {
    cityFilter = cityId;
    return [event];
  }

  @override
  Future<EventActivity?> getEvent(String id) async =>
      id == eventId ? event : null;

  @override
  Uri? eventLink(String activityId) => null;

  @override
  Future<String?> myParticipation(String id) async => participation;

  @override
  Future<void> join(String id) async {
    changes.add('join:$id');
    participation = 'confirmed';
  }

  @override
  Future<void> leave(String id) async {
    changes.add('leave:$id');
    participation = 'cancelled';
  }

  @override
  Future<List<EventUpdate>> updates() async => [
    EventUpdate({
      'id': updateId,
      'activity_id': eventId,
      'title': eventTitle,
      'kind': 'changed',
      'starts_at': startsAt.toIso8601String(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'timezone': 'Europe/Zurich',
      'place_name': 'Rowing clubhouse',
      'schedule_changed': true,
      'read_at': read ? DateTime.now().toUtc().toIso8601String() : null,
    }),
  ];

  @override
  Future<void> markUpdateRead(String id) async {
    changes.add('read:$id');
    read = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await initializeDateFormatting('en');
  });

  testWidgets('Guests filter events and can sign in from a detail', (
    tester,
  ) async {
    final service = _FakeEvents();
    String? signInEventId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventsScreen(
            service: service,
            signedIn: false,
            onEventSignIn: (id) => signInEventId = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.text('All cities'));
    await _tap(tester, find.text('Zurich').last);
    expect(service.cityFilter, 'zurich');

    await _tap(tester, find.text(eventTitle));
    expect(find.text('Organized by Lakeside Club'), findsOneWidget);
    expect(find.text('Seestrasse 12'), findsOneWidget);
    expect(find.text('3 places available'), findsOneWidget);
    await _tap(tester, find.text('Sign in to join'));
    expect(signInEventId, eventId);
    expect(service.changes, isEmpty);
  });

  testWidgets('Participants can join, leave, and open an unread update', (
    tester,
  ) async {
    final service = _FakeEvents();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EventsScreen(service: service, signedIn: true)),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.text(eventTitle));
    await _tap(tester, find.text('Join event'));
    expect(find.text('Going'), findsOneWidget);
    expect(find.text('2 places available'), findsOneWidget);
    await _tap(tester, find.text('Leave event'));
    expect(find.text('Not going'), findsOneWidget);
    expect(find.text('3 places available'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await _tap(tester, find.byTooltip('Event updates'));
    await _tap(
      tester,
      find.descendant(of: find.byType(Dialog), matching: find.text(eventTitle)),
    );
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Not going'), findsOneWidget);
    expect(service.changes, [
      'join:$eventId',
      'leave:$eventId',
      'read:$updateId',
    ]);
  });
}
