import 'package:supabase_flutter/supabase_flutter.dart';

import 'activity.dart';

import 'package:flutter/foundation.dart';

class ActivityService {
  ActivityService(this.client);
  final SupabaseClient client;
  RealtimeChannel? watch(VoidCallback changed) {
    final channel = client.channel(
      'activity_home_${client.auth.currentUser?.id}',
    );
    return channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'activities',
      callback: (_) => changed(),
    ).subscribe();
  }

  Future<List<Activity>> feed() async =>
      (await client.rpc('activity_feed') as List)
          .map((row) => Activity(Map<String, dynamic>.from(row as Map)))
          .toList();
  Future<String> create(
    Map<String, dynamic> details,
    List<String> friends,
  ) async => await client.rpc(
    'create_activity',
    params: {'details': details, 'friend_ids': friends},
  ) as String;
  Future<String> respond(String id, String response) async => await client.rpc(
    'respond_to_activity',
    params: {'target_activity_id': id, 'response': response},
  ) as String;
  Future<void> publish(String id, String visibility, String policy) async {
    await client.rpc(
      'publish_activity',
      params: {
        'target_activity_id': id,
        'new_visibility': visibility,
        'new_join_policy': policy,
      },
    );
  }

  Future<List<Map<String, dynamic>>> roster(String id) async =>
      List<Map<String, dynamic>>.from(
        await client.rpc(
          'activity_host_roster',
          params: {'target_activity_id': id},
        ),
      );
  Future<void> review(String id, String userId, bool approve) async {
    await client.rpc(
      'review_activity_request',
      params: {
        'target_activity_id': id,
        'participant_user_id': userId,
        'approve': approve,
      },
    );
  }
}
