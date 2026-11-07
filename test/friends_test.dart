import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zurich_games/friends/friend_service.dart';
import 'package:zurich_games/friends/friends_section.dart';
import 'package:zurich_games/main.dart';

import 'widget_test.dart' as helpers;

class FakeFriends extends FriendService {
  FakeFriends(SupabaseClient client, SharedPreferences preferences)
    : super(client, preferences, Uri.parse('http://localhost:3000/'));
  int accepts = 0;
  bool self = false;
  bool invalid = false;
  @override
  RealtimeChannel? watchFriends(VoidCallback changed) => null;
  @override
  Future<List<Map<String, dynamic>>> list() async => accepts == 0
      ? []
      : [
          {'username': 'sam'},
        ];
  @override
  Future<Map<String, dynamic>?> preview(String token) async => invalid
      ? null
      : {'username': 'sam', 'is_self': self, 'already_friends': accepts > 0};
  @override
  Future<Map<String, dynamic>> invitation({bool rotate = false}) async => {
    'token': 'a' * 64,
    'expires_at': '2026-11-14T10:00:00Z',
  };
  @override
  Future<void> accept(String token) async {
    accepts++;
  }
}

void main() {
  const token =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late FakeFriends friends;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    friends = FakeFriends(
      SupabaseClient('http://localhost:54321', 'public-key'),
      await SharedPreferences.getInstance(),
    );
  });
  tearDown(() {
    friends.dispose();
  });
  test(
    'Invitation parser accepts only own origin/app scheme and valid token',
    () {
      final base = Uri.parse('http://localhost:3000/');
      expect(
        invitationToken(
          Uri.parse('http://localhost:3000/?friend=$token'),
          base,
        ),
        token,
      );
      expect(
        invitationToken(Uri.parse('citytogether://friend?friend=$token'), base),
        token,
      );
      expect(
        invitationToken(Uri.parse('https://evil.example/?friend=$token'), base),
        isNull,
      );
      expect(
        invitationToken(Uri.parse('http://localhost:3000/?friend=123'), base),
        isNull,
      );
    },
  );
  test(
    'Pending invitation persists and an older dialog cannot clear a newer link',
    () async {
      await friends.receive(Uri.parse(friends.linkFor(token)));
      final restored = FriendService(
        friends.client,
        friends.preferences,
        friends.publicBase,
      );
      expect(restored.pendingToken, token);
      final newer = 'b' * 64;
      await friends.receive(Uri.parse(friends.linkFor(newer)));
      await friends.clearPending(token);
      expect(friends.pendingToken, newer);
      await friends.clearPending(newer);
      expect(friends.pendingToken, isNull);
      restored.dispose();
    },
  );
  testWidgets('Personal invitation shows QR code and copyable link', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: FriendsSection(service: friends)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await helpers.tapText(tester, 'My QR code & link');
    expect(find.text('Your friend invitation'), findsOneWidget);
    expect(find.text(friends.linkFor(token)), findsOneWidget);
    expect(
      find.bySemanticsLabel('Your friend invitation QR code'),
      findsOneWidget,
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await helpers.tapText(tester, 'Copy link');
    expect(copied, friends.linkFor(token));
    expect(
      find.text('Link copied. You can send it to a friend.'),
      findsOneWidget,
    );
  });
  testWidgets('Preview and cancel do not add; confirming adds once', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: FriendsSection(service: friends)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await friends.receive(Uri.parse(friends.linkFor(token)));
    await tester.pumpAndSettle();
    expect(find.text('Add sam as a friend?'), findsOneWidget);
    expect(friends.accepts, 0);
    await helpers.tapText(tester, 'Cancel');
    expect(friends.accepts, 0);
    await friends.receive(Uri.parse(friends.linkFor(token)));
    await tester.pumpAndSettle();
    await helpers.tapText(tester, 'Add friend');
    expect(friends.accepts, 1);
    expect(find.text('sam'), findsOneWidget);
    await friends.receive(Uri.parse(friends.linkFor(token)));
    await tester.pumpAndSettle();
    expect(find.text('Already friends'), findsOneWidget);
    expect(find.text('Add friend'), findsNothing);
  });
  testWidgets('Own and expired invitations cannot be accepted', (tester) async {
    friends.self = true;
    await friends.receive(Uri.parse(friends.linkFor(token)));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FriendsSection(service: friends)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This is your invitation'), findsOneWidget);
    await helpers.tapText(tester, 'Close');
    friends.invalid = true;
    await friends.receive(Uri.parse(friends.linkFor(token)));
    await tester.pumpAndSettle();
    expect(find.textContaining('This invitation has expired'), findsOneWidget);
    expect(friends.accepts, 0);
  });
  testWidgets(
    'Incoming link survives login and opens confirmation on profile',
    (tester) async {
      await friends.receive(Uri.parse(friends.linkFor(token)));
      final auth = helpers.FakeAuth();
      await tester.pumpWidget(CityApp(service: auth, friends: friends));
      await helpers.tapText(tester, 'Sign in');
      await helpers.enter(tester, 'Email', 'alex@example.com');
      await helpers.enter(tester, 'Password', 'valid-password');
      await helpers.tapText(tester, 'Sign in');
      expect(find.text('Add sam as a friend?'), findsOneWidget);
      expect(friends.accepts, 0);
      await helpers.tapText(tester, 'Add friend');
      expect(friends.accepts, 1);
    },
  );
}
