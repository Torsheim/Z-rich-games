import 'package:supabase_flutter/supabase_flutter.dart';

class EventRequestException implements Exception {
  const EventRequestException(this.message);
  final String message;

  @override
  String toString() => message;
}

class EventCity {
  const EventCity(this.id, this.name, this.slug, this.timezone);

  final String id, name, timezone;
  final String? slug;
}

class EventCategory {
  const EventCategory(this.id, this.name, this.slug);

  final String id, name;
  final String? slug;
}

class EventCatalog {
  const EventCatalog({required this.cities, required this.categories});

  final List<EventCity> cities;
  final List<EventCategory> categories;
}

class EventOrganization {
  const EventOrganization(this.id, this.name, this.role);

  final String id, name, role;
  bool get canPublish => role == 'owner' || role == 'admin';
}

class EventActivity {
  EventActivity(this._data);

  final Map<String, dynamic> _data;
  String get id => _data['id'] as String;
  String get title => _data['title'] as String;
  String get organizationId => _data['organizer_id'] as String;
  String get organizationName => _data['organizer_name'] as String;
  String get cityId => _data['city_id'] as String;
  String get cityName => _data['city_name'] as String;
  String get categoryId => _data['category_id'] as String;
  String get categoryName => _data['category_name'] as String;
  String get timezone => _data['timezone'] as String;
  String get placeName => _data['place_name'] as String;
  String get status => _data['status'] as String? ?? 'active';
  String get visibility => _data['visibility'] as String? ?? 'public';
  String get joinPolicy => _data['join_policy'] as String;
  String get _startsAtValue => _data['starts_at'] as String;
  DateTime get startsAt => DateTime.parse(_startsAtValue);
  DateTime? get endsAt => DateTime.tryParse(_data['ends_at'] as String? ?? '');
  DateTime? get cancelledAt =>
      DateTime.tryParse(_data['cancelled_at'] as String? ?? '');
  String? get address => _data['address'] as String?;
  String? get description => _data['description'] as String?;
  String? get coverImageUrl => _data['cover_image_url'] as String?;
  String? get cancellationReason => _data['cancellation_reason'] as String?;
  int? get availablePlaces => (_data['available_places'] as num?)?.toInt();
  int? get maxParticipants => (_data['max_participants'] as num?)?.toInt();
  double? get latitude => (_data['latitude'] as num?)?.toDouble();
  double? get longitude => (_data['longitude'] as num?)?.toDouble();
}

class EventParticipant {
  const EventParticipant(this.userId, this.username, this.confirmedAt);

  final String userId, username;
  final DateTime confirmedAt;
}

class EventUpdate {
  EventUpdate(this._data);

  final Map<String, dynamic> _data;
  String get id => _data['id'] as String;
  String get activityId => _data['activity_id'] as String;
  String get title => _data['title'] as String;
  String get kind => _data['kind'] as String;
  String get timezone => _data['timezone'] as String;
  String get placeName => _data['place_name'] as String;
  DateTime get startsAt => DateTime.parse(_data['starts_at'] as String);
  DateTime get createdAt => DateTime.parse(_data['created_at'] as String);
  DateTime? get readAt => DateTime.tryParse(_data['read_at'] as String? ?? '');
  bool get scheduleChanged => _data['schedule_changed'] == true;
  bool get venueChanged => _data['venue_changed'] == true;
  String? get address => _data['address'] as String?;
  String? get cancellationReason => _data['cancellation_reason'] as String?;
}

class EventService {
  EventService(this._client, {this.publicUrl});

  static const pageSize = 20;
  final SupabaseClient _client;
  final Uri? publicUrl;

  Uri? eventLink(String activityId) =>
      publicUrl?.replace(queryParameters: {'event': activityId}, fragment: '');

  Future<dynamic> _rpc(String name, [Map<String, dynamic>? params]) async {
    try {
      return await _client.rpc(name, params: params);
    } on PostgrestException catch (error) {
      throw EventRequestException(switch (error.details) {
        'activity_full' =>
          'This event is full. Refresh to check for a free place.',
        'activity_closed' => 'This event is closed for participation changes.',
        _ => switch (error.code) {
          '42501' => 'You do not have permission to do this.',
          '55000' => 'The event has changed. Refresh and try again.',
          '22023' => error.message,
          _ => 'Could not complete the request. Please try again.',
        },
      });
    } on Exception {
      throw const EventRequestException(
        'Could not reach the event service. Please try again.',
      );
    }
  }

  Iterable<Map<String, dynamic>> _rows(dynamic value) =>
      (value as List).map((row) => Map<String, dynamic>.from(row as Map));

  Map<String, dynamic> _activity(String id) => {'p_activity_id': id};

  Future<EventCatalog> catalog() async {
    final data = await _rpc('list_activity_options') as Map;
    return EventCatalog(
      cities: _rows(data['cities'])
          .map(
            (row) => EventCity(
              row['id'] as String,
              row['name'] as String,
              row['slug'] as String?,
              row['timezone'] as String,
            ),
          )
          .toList(),
      categories: _rows(data['categories'])
          .map(
            (row) => EventCategory(
              row['id'] as String,
              row['name'] as String,
              row['slug'] as String?,
            ),
          )
          .toList(),
    );
  }

  Future<List<EventActivity>> listEvents({
    String? cityId,
    String? categoryId,
    EventActivity? after,
  }) async => _rows(
    await _rpc('list_public_activities', {
      'p_organization_only': true,
      'p_limit': pageSize,
      'p_city_id': ?cityId,
      'p_category_id': ?categoryId,
      if (after != null) ...{
        'p_after_starts_at': after._startsAtValue,
        'p_after_activity_id': after.id,
      },
    }),
  ).map(EventActivity.new).toList();

  Future<EventActivity?> getEvent(String id) async {
    final row = _rows(await _rpc('get_organization_event', _activity(id)))
        .firstOrNull;
    return row == null ? null : EventActivity(row);
  }

  Future<String?> myParticipation(String id) async =>
      await _rpc('get_my_activity_participation', _activity(id)) as String?;

  Future<void> join(String id) async {
    await _rpc('join_activity', _activity(id));
  }

  Future<void> leave(String id) async {
    await _rpc('leave_activity', _activity(id));
  }

  Future<List<EventUpdate>> updates() async =>
      _rows(await _rpc('list_my_event_updates')).map(EventUpdate.new).toList();

  Future<void> markUpdateRead(String id) async {
    await _rpc('mark_event_update_read', {'p_update_id': id});
  }

  Future<List<EventOrganization>> organizations() async =>
      _rows(await _rpc('list_my_event_organizations'))
          .map(
            (row) => EventOrganization(
              row['id'] as String,
              row['name'] as String,
              row['role'] as String,
            ),
          )
          .toList();

  Future<List<EventActivity>> managedEvents(String organizationId) async =>
      _rows(
        await _rpc('list_managed_organization_events', {
          'p_organizer_id': organizationId,
        }),
      ).map(EventActivity.new).toList();

  Future<List<EventParticipant>> participants(String eventId) async =>
      _rows(
            await _rpc(
              'list_organization_event_participants',
              _activity(eventId),
            ),
          )
          .map(
            (row) => EventParticipant(
              row['user_id'] as String,
              row['username'] as String,
              DateTime.parse(row['confirmed_at'] as String),
            ),
          )
          .toList();

  Future<String> createDraft(
    String organizationId,
    Map<String, dynamic> fields,
  ) async => await _rpc('create_activity_draft', {
    'p_organizer_id': organizationId,
    for (final field in fields.entries) 'p_${field.key}': field.value,
  }) as String;

  Future<void> edit(String id, Map<String, dynamic> changes) async {
    await _rpc('update_activity', {..._activity(id), 'p_changes': changes});
  }

  Future<void> publish(String id) async {
    await _rpc('publish_activity', _activity(id));
  }

  Future<void> cancel(String id, {String? reason}) async {
    await _rpc('cancel_activity', {..._activity(id), 'p_reason': reason});
  }
}
