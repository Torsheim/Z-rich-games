import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

const activityCategories = {
  'social': 'Social',
  'culture': 'Culture',
  'outdoors': 'Outdoors',
  'food': 'Food & drink',
  'sport': 'Sport',
};
IconData categoryIcon(String category) => switch (category) {
  'culture' => Icons.museum_outlined,
  'outdoors' => Icons.landscape_outlined,
  'food' => Icons.restaurant_outlined,
  'sport' => Icons.sports_tennis_outlined,
  _ => Icons.forum_outlined,
};
Color categoryColor(String category) => switch (category) {
  'culture' => const Color(0xFF7957A0),
  'outdoors' => const Color(0xFF26755C),
  'food' => const Color(0xFFAD6136),
  'sport' => const Color(0xFF3969A1),
  _ => const Color(0xFF9C6046),
};

class Activity {
  Activity(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get title => data['title'] as String;
  String get category => data['category_id'] as String;
  String get host => data['host_username'] as String;
  String get creator => data['created_by_user_id'] as String;
  String get place => data['place_name'] as String;
  String get visibility => data['visibility'] as String;
  String get policy => data['join_policy'] as String;
  String get state => data['status'] as String;
  String? get myStatus => data['my_status'] as String?;
  String? get invitation => data['invite_status'] as String?;
  bool get demo => data['demo'] == true;
  int get count => (data['participant_count'] as num).toInt();
  int? get limit => (data['max_participants'] as num?)?.toInt();
  bool get full => limit != null && count >= limit!;
  bool get open => state == 'active' && start.isAfter(DateTime.now());
  DateTime get start => DateTime.parse(data['starts_at'] as String);
  String get when => DateFormat('EEE, d MMM · HH:mm', 'en').format(
    tz.TZDateTime.from(start, tz.getLocation(data['timezone'] as String)),
  );
  String get attendance => data['is_host'] == true
      ? 'Hosting'
      : switch (myStatus) {
          'confirmed' => 'Going',
          'requested' => 'Request pending',
          'cancelled' => 'Not going',
          'rejected' => 'Request declined',
          _ =>
            invitation == 'pending'
                ? 'Invitation'
                : full
                ? 'Full'
                : 'Open to join',
        };
  Activity withData(Map<String, dynamic> changes) =>
      Activity({...data, ...changes});
}

List<Activity> exampleActivities(String userId) {
  final tomorrow = tz.TZDateTime.now(tz.getLocation('Europe/Zurich'))
      .add(const Duration(days: 1));
  Map<String, dynamic> base(int n) => {
    'id': 'example-$n',
    'demo': true,
    'kind': 'activity',
    'created_by_user_id': 'example-host',
    'title': '',
    'description': '',
    'category_id': 'social',
    'host_username': 'Maya',
    'visibility': 'invite_only',
    'join_policy': 'invitation_required',
    'max_participants': 6,
    'starts_at': tz.TZDateTime(
      tomorrow.location,
      tomorrow.year,
      tomorrow.month,
      tomorrow.day + n - 1,
      18,
      30,
    ).toUtc().toIso8601String(),
    'ends_at': null,
    'timezone': 'Europe/Zurich',
    'city_id': 'zurich',
    'place_name': '',
    'address': '',
    'status': 'active',
    'participant_count': 3,
    'my_status': null,
    'invite_status': null,
  };
  return [
    Activity({
      ...base(1),
      'title': 'An evening at the Kunsthaus',
      'category_id': 'culture',
      'place_name': 'Kunsthaus Zurich',
      'address': 'Heimplatz 1, Zurich',
      'description': 'A relaxed wander through the galleries. Meet by the main entrance; everyone buys their own ticket.',
      'invite_status': 'pending',
    }),
    Activity({
      ...base(2),
      'title': 'Friday bowling crew',
      'category_id': 'sport',
      'place_name': 'Bowling meeting point',
      'address': 'Meet at the reception desk',
      'description': 'A friendly game together. All six places are currently taken. You can decline or check back for a free spot.',
      'host_username': 'Alex',
      'participant_count': 6,
      'invite_status': 'pending',
    }),
    Activity({
      ...base(3),
      'title': 'Lakeside walk & a coffee',
      'category_id': 'outdoors',
      'place_name': 'Bürkliplatz fountain',
      'address': 'Bürkliplatz, Zurich',
      'description': 'An easy walk along the lake. No special equipment needed. We will choose a café together afterwards.',
      'host_username': 'Noah',
      'participant_count': 4,
      'max_participants': 8,
      'my_status': 'confirmed',
    }),
    Activity({
      ...base(4),
      'title': 'A table for a few more',
      'category_id': 'food',
      'place_name': 'Dinner in the old town',
      'address': 'Meet outside the restaurant entrance',
      'description': 'Dinner with friends. Start privately, then open up the remaining seats if you would like more people to join.',
      'host_username': 'You',
      'created_by_user_id': userId,
      'is_host': true,
      'my_status': 'confirmed',
    }),
    Activity({
      ...base(5),
      'title': 'Darts, drinks & new faces',
      'place_name': 'City centre bar',
      'address': 'Meeting point at the darts boards',
      'description': 'A casual darts night for all skill levels. Request a place and the host will confirm your spot.',
      'host_username': 'Sam',
      'visibility': 'public',
      'join_policy': 'approval_required',
      'participant_count': 5,
      'max_participants': 8,
    }),
  ];
}
