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
  final _advancedForm = GlobalKey<FormState>();
  final _options = ExpansibleController();
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
  bool _unlimited = true, _busy = false;
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
    _options.dispose();
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
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        counterText: '',
      ),
      validator:
          validate ??
          (value) => required && (value?.trim().length ?? 0) < 3
              ? 'Enter at least 3 characters.'
              : null,
    ),
  );
  Future<void> _save() async {
    if (_busy) return;
    final basicValid = _form.currentState!.validate();
    final advancedValid = _advancedForm.currentState!.validate();
    if (!advancedValid) _options.expand();
    if (!basicValid || !advancedValid) return;
    if (!_start.isAfter(DateTime.now())) {
      setState(() => _error = 'Choose a future start time.');
      return;
    }
    if (_end != null && _end!.isBefore(_start)) {
      _options.expand();
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
      _advancedForm.currentState!.reset();
      _options.collapse();
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
        _category = 'social';
        _unlimited = true;
        _limit.text = '6';
        _end = null;
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

  Future<void> _chooseFriends() async {
    final selected = Set<String>.of(_invited);
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => FutureBuilder<List<Map<String, dynamic>>>(
          future: _friends,
          builder: (context, snapshot) => AlertDialog(
            title: const Text('Invite friends'),
            content: SizedBox(
              width: 360,
              height: 260,
              child: snapshot.hasError
                  ? Center(
                      child: TextButton(
                        onPressed: () {
                          final next =
                              widget.friends?.list() ??
                              Future<List<Map<String, dynamic>>>.value([]);
                          update(() {
                            _friends = next;
                          });
                        },
                        child: const Text('Retry friends'),
                      ),
                    )
                  : !snapshot.hasData
                  ? const Center(child: CircularProgressIndicator())
                  : snapshot.data!.isEmpty
                  ? const Center(
                      child: Text(
                        'No friends yet. Add friends from your profile first.',
                      ),
                    )
                  : ListView(
                      children: snapshot.data!
                          .map(
                            (friend) => CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(friend['username'] as String),
                              value: selected.contains(friend['user_id']),
                              onChanged: (value) => update(() {
                                if (value == true) {
                                  selected.add(friend['user_id'] as String);
                                } else {
                                  selected.remove(friend['user_id']);
                                }
                              }),
                            ),
                          )
                          .toList(),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: !snapshot.hasData
                    ? null
                    : () {
                        final allowed = snapshot.data!
                            .map((f) => f['user_id'])
                            .toSet();
                        Navigator.pop(
                          context,
                          selected.where(allowed.contains).toSet(),
                        );
                      },
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _invited.clear();
        _invited.addAll(result);
      });
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 36),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Make a plan',
                  style: Theme.of(context).textTheme.headlineLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Something to do. Friends to do it with.',
                  style: TextStyle(color: Color(0xFF64736D)),
                ),
                const SizedBox(height: 28),
                _field(
                  'Activity title',
                  _title,
                  required: true,
                  maxLength: 100,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_outlined, size: 22),
                  title: const Text('When'),
                  subtitle: Text(
                    DateFormat('EEE, d MMM · HH:mm', 'en').format(_start),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: _busy ? null : () => _chooseTime(false),
                ),
                const SizedBox(height: 16),
                _field('Meeting point', _place, required: true, maxLength: 160),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.people_outline, size: 22),
                  title: const Text('Invite friends'),
                  subtitle: Text(
                    _invited.isEmpty
                        ? 'Choose from your friends'
                        : '${_invited.length} selected',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: _busy ? null : _chooseFriends,
                ),
                const SizedBox(height: 12),
                Text(
                  '${_status == 'draft' ? 'Draft · ' : ''}${_visibility == 'invite_only' ? 'Invite only' : 'Public'} · ${_unlimited ? 'no participant limit' : 'up to ${_limit.text} people'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64736D),
                  ),
                ),
                const SizedBox(height: 16),
                ExpansionTile(
                  controller: _options,
                  maintainState: true,
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    'More options',
                    style: TextStyle(fontSize: 14),
                  ),
                  children: [
                    Form(
                      key: _advancedForm,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 12),
                          _field(
                            'Description',
                            _description,
                            lines: 3,
                            maxLength: 4000,
                          ),
                          DropdownButtonFormField<String>(
                            key: ValueKey('category_$_category'),
                            initialValue: _category,
                            decoration: const InputDecoration(
                              labelText: 'Category',
                            ),
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
                                : (value) => setState(() => _category = value!),
                          ),
                          const SizedBox(height: 16),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Ends (optional)'),
                            subtitle: Text(
                              _end == null
                                  ? 'Add an end time'
                                  : DateFormat(
                                      'EEE, d MMM · HH:mm',
                                      'en',
                                    ).format(_end!),
                            ),
                            onTap: _busy ? null : () => _chooseTime(true),
                            trailing: _end == null
                                ? const Icon(Icons.add, size: 20)
                                : IconButton(
                                    tooltip: 'Clear end time',
                                    onPressed: _busy
                                        ? null
                                        : () => setState(() => _end = null),
                                    icon: const Icon(Icons.close),
                                  ),
                          ),
                          const SizedBox(height: 12),
                          _field(
                            'Address (optional)',
                            _address,
                            maxLength: 300,
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('No participant limit'),
                            value: _unlimited,
                            onChanged: _busy
                                ? null
                                : (value) => setState(() => _unlimited = value),
                          ),
                          if (!_unlimited)
                            _field(
                              'Maximum participants',
                              _limit,
                              keyboard: TextInputType.number,
                              validate: (value) {
                                final count = int.tryParse(value ?? '');
                                return count == null ||
                                        count < 1 ||
                                        count > 10000
                                    ? 'Enter a whole number from 1 to 10,000.'
                                    : null;
                              },
                            ),
                          const SizedBox(height: 16),
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                value: 'invite_only',
                                label: Text('Invite only'),
                              ),
                              ButtonSegment(
                                value: 'public',
                                label: Text('Public'),
                              ),
                            ],
                            selected: {_visibility},
                            onSelectionChanged: _busy
                                ? null
                                : (value) =>
                                      setState(() => _visibility = value.first),
                          ),
                          if (_visibility == 'public') ...[
                            const SizedBox(height: 12),
                            const Text(
                              'Your description and meeting point will be visible to other signed-in users.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF64736D),
                              ),
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
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
                                  : (value) => setState(() => _policy = value!),
                            ),
                          ],
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            key: ValueKey('status_$_status'),
                            initialValue: _status,
                            decoration: const InputDecoration(
                              labelText: 'Create as',
                            ),
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
                            onChanged: _busy
                                ? null
                                : (value) => setState(() => _status = value!),
                          ),
                          const SizedBox(height: 16),
                          _field(
                            'Cover image URL (optional)',
                            _cover,
                            keyboard: TextInputType.url,
                            validate: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return null;
                              }
                              final uri = Uri.tryParse(value.trim());
                              return uri?.scheme == 'https' &&
                                      uri!.host.isNotEmpty
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
                            validate: (value) {
                              if ((value ?? '').trim().isEmpty) {
                                return _longitude.text.trim().isEmpty
                                    ? null
                                    : 'Enter both coordinates.';
                              }
                              final number = double.tryParse(value!);
                              return number != null &&
                                      number.isFinite &&
                                      number >= -90 &&
                                      number <= 90
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
                            validate: (value) {
                              if ((value ?? '').trim().isEmpty) {
                                return _latitude.text.trim().isEmpty
                                    ? null
                                    : 'Enter both coordinates.';
                              }
                              final number = double.tryParse(value!);
                              return number != null &&
                                      number.isFinite &&
                                      number >= -180 &&
                                      number <= 180
                                  ? null
                                  : 'Use a longitude between -180 and 180.';
                            },
                          ),
                          const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: Text(
                              'Zurich · Europe/Zurich',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF64736D),
                              ),
                            ),
                          ),
                        ],
                      ),
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
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'Creating…' : 'Create activity'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
