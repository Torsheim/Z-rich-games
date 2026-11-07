import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Only our own origin or app scheme is accepted, never arbitrary QR URLs.
String? invitationToken(Uri uri, Uri publicBase) {
  final allowed =
      (uri.scheme == 'citytogether' && uri.host == 'friend') ||
      (uri.originOrNull == publicBase.originOrNull &&
          (uri.scheme == 'http' || uri.scheme == 'https'));
  final token = uri.queryParameters['friend'];
  return allowed && token != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(token)
      ? token
      : null;
}

extension on Uri {
  String? get originOrNull =>
      hasAuthority && (scheme == 'http' || scheme == 'https') ? origin : null;
}

class FriendService extends ChangeNotifier {
  FriendService(this.client, this.preferences, this.publicBase);
  final SupabaseClient client;
  final SharedPreferences preferences;
  final Uri publicBase;
  StreamSubscription<Uri>? _links;
  String get _pendingKey => 'city_pending_friend_${client.rest.url}';
  String? get pendingToken => preferences.getString(_pendingKey);

  Future<void> initialize() async {
    if (kIsWeb) {
      await receive(Uri.base);
    } else {
      final links = AppLinks();
      final initial = await links.getInitialLink();
      if (initial != null) await receive(initial);
      _links = links.uriLinkStream.listen(
        (uri) => unawaited(receive(uri)),
        onError: (_) {},
      );
    }
  }

  Future<void> receive(Uri uri) async {
    final token = invitationToken(uri, publicBase);
    if (token == null) return;
    await preferences.setString(_pendingKey, token);
    notifyListeners();
  }

  Future<void> clearPending(String expectedToken) async {
    if (pendingToken != expectedToken) return;
    await preferences.remove(_pendingKey);
    notifyListeners();
  }

  String linkFor(String token) => publicBase
      .replace(queryParameters: {'friend': token}, fragment: '')
      .toString();
  RealtimeChannel? watchFriends(VoidCallback changed) => client
      .channel('friends_${client.auth.currentUser?.id}')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'friendships',
        callback: (_) => changed(),
      )
      .subscribe();
  Future<List<Map<String, dynamic>>> list() async =>
      List<Map<String, dynamic>>.from(await client.rpc('my_friends'));
  Future<Map<String, dynamic>> invitation({bool rotate = false}) async =>
      Map<String, dynamic>.from(
        (await client.rpc(
          'my_friend_invite',
          params: {'rotate': rotate},
        ) as List).single,
      );
  Future<Map<String, dynamic>?> preview(String token) async {
    final rows = await client.rpc(
      'preview_friend_invite',
      params: {'invite_token': token},
    ) as List;
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.single);
  }

  Future<void> accept(String token) async {
    await client.rpc('accept_friend_invite', params: {'invite_token': token});
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }
}
