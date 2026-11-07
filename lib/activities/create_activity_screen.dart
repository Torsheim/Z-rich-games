import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../friends/friend_service.dart';
import 'activity.dart';

class CreateActivityScreen extends StatefulWidget {
  const CreateActivityScreen({
    super.key,
    required this.friends,
    required this.onCreate,
    this.revision = 0,
  });
  final FriendService? friends;
  final int revision;
  final Future<void> Function(Map<String, dynamic>, List<String>) onCreate;
  @override
  State<CreateActivityScreen> createState() => _CreateActivityScreenState();
}

class _CreateActivityScreenState extends State<CreateActivityScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController(),
      _description = TextEditingController(),
      _place = TextEditingController(),
      _address = TextEditingController(),
      _limit = TextEditingController(text: '6'),
      _cover = TextEditingController(),
      _latitude = TextEditingController(),
      _longitude = TextEditingController();
  final Set<String> _invited = {};
  late Future<List<Map<String, dynamic>>> _friends;
  String _category = 'social',
      _visibility = 'invite_only',
      _policy = 'instant',
      _status = 'active';
  late tz.TZDateTime _start;
  tz.TZDateTime? _end;
  bool _unlimited = false, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _friends = widget.friends?.list() ?? Future.value([]);
    final now = tz.TZDateTime.now(tz.getLocation('Europe/Zurich'))
        .add(const Duration(days: 1));
    _start = tz.TZDateTime(now.location, now.year, now.month, now.day, 18, 30);
  }

  @override
  void didUpdateWidget(covariant CreateActivityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      _friends = widget.friends?.list() ?? Future.value([]);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _description,
      _place,
      _address,
      _limit,
      _cover,
      _latitude,
      _longitude,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseTime(bool end) async {
    final initial = end
        ? (_end ?? _start.add(const Duration(hours: 2)))
        : _start;
    final today = tz.TZDateTime.now(_start.location);
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: DateTime(today.year + 2),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final value = tz.TZDateTime(
      _start.location,
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (end) {
        _end = value;
      } else {
        _start = value;
      }
    });
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool required = false,
    int lines = 1,
    int? maxLength,
    String? helper,
    TextInputType? keyboard,
    String? Function(String?)? validate,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: !_busy,
      maxLines: lines,
      maxLength: maxLength,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, helperText: helper),
      validator:
          validate ??
          (value) => required && (value?.trim().length ?? 0) < 3
              ? 'Enter at least 3 characters.'
              : null,
    ),
  );
  Widget _section(String number, String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: const Color(0xFFE2EDE7),
          child: Text(number, style: const TextStyle(fontSize: 13)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (!_start.isAfter(DateTime.now())) {
      setState(() => _error = 'Choose a future start time.');
      return;
    }
    if (_end != null && _end!.isBefore(_start)) {
      setState(() => _error = 'End time must be after the start.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate({
        'kind': 'activity',
        'title': _title.text.trim(),
        'description': _description.text.trim(),
        'category_id': _category,
        'cover_image_url': _cover.text.trim(),
        'city_id': 'zurich',
        'timezone': 'Europe/Zurich',
        'place_name': _place.text.trim(),
        'address': _address.text.trim(),
        'latitude': double.tryParse(_latitude.text.trim()),
        'longitude': double.tryParse(_longitude.text.trim()),
        'starts_at': _start.toUtc().toIso8601String(),
        'ends_at': _end?.toUtc().toIso8601String(),
        'max_participants': _unlimited ? null : int.parse(_limit.text),
        'visibility': _visibility,
        'join_policy': _visibility == 'invite_only'
            ? 'invitation_required'
            : _policy,
        'status': _status,
      }, _invited.toList());
      if (!mounted) return;
      _form.currentState!.reset();
      for (final c in [
        _title,
        _description,
        _place,
        _address,
        _cover,
        _latitude,
        _longitude,
      ]) {
        c.clear();
      }
      setState(() {
        _invited.clear();
        _visibility = 'invite_only';
        _policy = 'instant';
        _status = 'active';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not create the activity. Check the details and your connection, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Make a plan',
                  style: Theme.of(context).textTheme.headlineLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Start with your friends. Open the remaining places to the city whenever you’re ready.',
                ),
                _section(
                  '1',
                  'The idea',
                  'Keep it simple. What would you like to do?',
                ),
                _field(
                  'Activity title',
                  _title,
                  required: true,
                  maxLength: 100,
                ),
                _field(
                  'Description',
                  _description,
                  lines: 3,
                  maxLength: 4000,
                  helper: 'The plan, what to bring, and anything people should know.',
                ),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: activityCategories.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _category = v!),
                ),
                _section(
                  '2',
                  'When & where',
                  'Zurich · times shown in Europe/Zurich.',
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_outlined),
                  title: const Text('Starts'),
                  subtitle: Text(
                    DateFormat('EEE, d MMM yyyy · HH:mm', 'en').format(_start),
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: _busy ? null : () => _chooseTime(false),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: const Text('Ends (optional)'),
                  subtitle: Text(
                    _end == null
                        ? 'Add an end time'
                        : DateFormat(
                            'EEE, d MMM yyyy · HH:mm',
                            'en',
                          ).format(_end!),
                  ),
                  onTap: _busy ? null : () => _chooseTime(true),
                  trailing: _end == null
                      ? const Icon(Icons.add)
                      : IconButton(
                          tooltip: 'Clear end time',
                          onPressed: _busy
                              ? null
                              : () => setState(() => _end = null),
                          icon: const Icon(Icons.close),
                        ),
                ),
                const SizedBox(height: 16),
                _field(
                  'Meeting point',
                  _place,
                  required: true,
                  maxLength: 160,
                  helper:
                      'For example: the fountain, main entrance or reception.',
                ),
                _field('Address (optional)', _address, maxLength: 300),
                _section(
                  '3',
                  'Your people',
                  'You count as one participant. Invitations do not reserve places.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('No participant limit'),
                  value: _unlimited,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _unlimited = v),
                ),
                if (!_unlimited)
                  _field(
                    'Maximum participants',
                    _limit,
                    keyboard: TextInputType.number,
                    validate: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 10000
                          ? 'Enter a whole number from 1 to 10,000.'
                          : null;
                    },
                  ),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: _friends,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Unable to load your friends.'),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () {
                                    final next =
                                        widget.friends?.list() ??
                                        Future<
                                          List<Map<String, dynamic>>
                                        >.value([]);
                                    setState(() {
                                      _friends = next;
                                    });
                                  },
                            child: const Text('Retry friends'),
                          ),
                        ],
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator(),
                      );
                    }
                    if (snapshot.data!.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No friends yet. Add friends from your profile to invite them here. You can still create a plan.',
                        ),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Invite friends · ${_invited.length} selected',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: snapshot.data!
                              .map(
                                (f) => FilterChip(
                                  label: Text(f['username'] as String),
                                  selected: _invited.contains(f['user_id']),
                                  onSelected: _busy
                                      ? null
                                      : (selected) => setState(() {
                                          if (selected) {
                                            _invited.add(
                                              f['user_id'] as String,
                                            );
                                          } else {
                                            _invited.remove(f['user_id']);
                                          }
                                        }),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    );
                  },
                ),
                _section(
                  '4',
                  'Who can join?',
                  'Private by default. You can publish it later without losing your group.',
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'invite_only',
                      label: Text('Invite only'),
                      icon: Icon(Icons.lock_outline),
                    ),
                    ButtonSegment(
                      value: 'public',
                      label: Text('Public'),
                      icon: Icon(Icons.public),
                    ),
                  ],
                  selected: {_visibility},
                  onSelectionChanged: _busy
                      ? null
                      : (v) => setState(() => _visibility = v.first),
                ),
                const SizedBox(height: 12),
                Text(
                  _visibility == 'invite_only'
                      ? 'Only the friends you invite can see and join this plan.'
                      : 'Your description and meeting point will be visible to other signed-in users.',
                ),
                if (_visibility == 'public')
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: DropdownButtonFormField<String>(
                      initialValue: _policy,
                      decoration: const InputDecoration(
                        labelText: 'Public joining',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'instant',
                          child: Text('Anyone can join'),
                        ),
                        DropdownMenuItem(
                          value: 'approval_required',
                          child: Text('I approve requests'),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _policy = v!),
                    ),
                  ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  decoration: const InputDecoration(labelText: 'Create as'),
                  items: const [
                    DropdownMenuItem(
                      value: 'active',
                      child: Text('Ready — send invitations'),
                    ),
                    DropdownMenuItem(
                      value: 'draft',
                      child: Text('Draft — only visible to me'),
                    ),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _status = v!),
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Optional details'),
                  children: [
                    _field(
                      'Cover image URL (optional)',
                      _cover,
                      keyboard: TextInputType.url,
                      validate: (v) {
                        if (v == null || v.trim().isEmpty) return null;
                        final u = Uri.tryParse(v.trim());
                        return u?.scheme == 'https' && u!.host.isNotEmpty
                            ? null
                            : 'Enter an HTTPS image URL.';
                      },
                    ),
                    _field(
                      'Latitude (optional)',
                      _latitude,
                      keyboard: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      validate: (v) {
                        if ((v ?? '').trim().isEmpty) {
                          return _longitude.text.trim().isEmpty
                              ? null
                              : 'Enter both coordinates.';
                        }
                        final n = double.tryParse(v!);
                        return n != null && n.isFinite && n >= -90 && n <= 90
                            ? null
                            : 'Use a latitude between -90 and 90.';
                      },
                    ),
                    _field(
                      'Longitude (optional)',
                      _longitude,
                      keyboard: const TextInputType.numberWithOptions(
                        signed: true,
                        decimal: true,
                      ),
                      validate: (v) {
                        if ((v ?? '').trim().isEmpty) {
                          return _latitude.text.trim().isEmpty
                              ? null
                              : 'Enter both coordinates.';
                        }
                        final n = double.tryParse(v!);
                        return n != null && n.isFinite && n >= -180 && n <= 180
                            ? null
                            : 'Use a longitude between -180 and 180.';
                      },
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.add),
                  label: Text(_busy ? 'Creating…' : 'Create activity'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'This creates a personal activity. Organizer events are managed separately.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
