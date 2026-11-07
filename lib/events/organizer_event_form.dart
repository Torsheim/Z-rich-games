import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import 'event_service.dart';

tz.Location _eventLocation(String name) {
  try {
    return tz.getLocation(name);
  } on tz.LocationNotFoundException {
    return tz.UTC;
  }
}

String formatOrganizerEventTime(DateTime value, String timezone) {
  final local = tz.TZDateTime.from(value, _eventLocation(timezone));
  return '${DateFormat('EEE, d MMM yyyy · HH:mm', 'en').format(local)} ${local.timeZoneName}';
}

class OrganizerEventForm extends StatefulWidget {
  const OrganizerEventForm({
    super.key,
    required this.service,
    required this.organization,
    this.event,
  });

  final EventService service;
  final EventOrganization organization;
  final EventActivity? event;

  @override
  State<OrganizerEventForm> createState() => _OrganizerEventFormState();
}

class _OrganizerEventFormState extends State<OrganizerEventForm> {
  late Future<EventCatalog> _catalog;

  @override
  void initState() {
    super.initState();
    _catalog = widget.service.catalog();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.event == null ? 'Create event draft' : 'Edit event'),
    ),
    body: SafeArea(
      child: FutureBuilder<EventCatalog>(
        future: _catalog,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(
                semanticsLabel: 'Loading event options',
              ),
            );
          }
          final catalog = snapshot.data;
          if (catalog == null ||
              (widget.event == null &&
                  (catalog.cities.isEmpty || catalog.categories.isEmpty))) {
            final error = snapshot.error;
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      error is EventRequestException
                          ? error.message
                          : 'Could not load event options.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () =>
                          setState(() => _catalog = widget.service.catalog()),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }
          return _EventFields(
            service: widget.service,
            organization: widget.organization,
            catalog: catalog,
            event: widget.event,
          );
        },
      ),
    ),
  );
}

class _EventFields extends StatefulWidget {
  const _EventFields({
    required this.service,
    required this.organization,
    required this.catalog,
    this.event,
  });

  final EventService service;
  final EventOrganization organization;
  final EventCatalog catalog;
  final EventActivity? event;

  @override
  State<_EventFields> createState() => _EventFieldsState();
}

class _EventFieldsState extends State<_EventFields> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title,
      _description,
      _place,
      _address,
      _capacity,
      _cover;
  late final Map<String, String> _cities, _timezones, _categories;
  late final Map<String, dynamic> _initialFields;
  late String _city, _timezone, _category;
  late DateTime _start;
  DateTime? _end;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final event = widget.event;
    _title = TextEditingController(text: event?.title);
    _description = TextEditingController(text: event?.description);
    _place = TextEditingController(text: event?.placeName);
    _address = TextEditingController(text: event?.address);
    _capacity = TextEditingController(text: event?.maxParticipants?.toString());
    _cover = TextEditingController(text: event?.coverImageUrl);
    _cities = {for (final city in widget.catalog.cities) city.id: city.name};
    _timezones = {
      for (final city in widget.catalog.cities) city.id: city.timezone,
    };
    _categories = {
      for (final category in widget.catalog.categories)
        category.id: category.name,
    };
    if (event != null) {
      _cities.putIfAbsent(event.cityId, () => event.cityName);
      _timezones.putIfAbsent(event.cityId, () => event.timezone);
      _categories.putIfAbsent(event.categoryId, () => event.categoryName);
    }
    _city = event?.cityId ?? _cities.keys.first;
    _timezone = event?.timezone ?? _timezones[_city]!;
    _category = event?.categoryId ?? _categories.keys.first;
    final location = _eventLocation(_timezone);
    final today = tz.TZDateTime.now(location);
    _start =
        event?.startsAt ??
        tz.TZDateTime(location, today.year, today.month, today.day + 1, 18);
    _end = event?.endsAt;
    _initialFields = _fields();
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _description,
      _place,
      _address,
      _capacity,
      _cover,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _optional(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  Map<String, dynamic> _fields() => {
    'title': _title.text.trim(),
    'description': _description.text.trim(),
    'category_id': _category,
    'city_id': _city,
    'timezone': _timezone,
    'starts_at': _start.toUtc().toIso8601String(),
    'ends_at': _end?.toUtc().toIso8601String(),
    'place_name': _place.text.trim(),
    'address': _optional(_address.text),
    'max_participants': int.tryParse(_capacity.text.trim(), radix: 10),
    'cover_image_url': _optional(_cover.text),
  };

  Future<void> _pickTime(bool isEnd) async {
    final location = _eventLocation(_timezone);
    final initial = tz.TZDateTime.from(
      isEnd ? _end ?? _start.add(const Duration(hours: 2)) : _start,
      location,
    );
    final localToday = tz.TZDateTime.now(location);
    final today = DateTime(localToday.year, localToday.month, localToday.day);
    final selected = DateTime(initial.year, initial.month, initial.day);
    final limit = DateTime(today.year + 3, 12, 31);
    final date = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: selected.isBefore(today) ? selected : today,
      lastDate: selected.isAfter(limit) ? selected : limit,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final picked = tz.TZDateTime(
      location,
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (picked.hour != time.hour ||
        picked.minute != time.minute ||
        picked.day != date.day) {
      setState(
        () => _error = 'That local time is skipped when the clocks change. Choose another time.',
      );
      return;
    }
    setState(() {
      if (isEnd) {
        _end = picked;
      } else {
        _start = picked;
      }
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    if (_end?.isBefore(_start) == true) {
      setState(() => _error = 'Choose an end time at or after the start.');
      return;
    }
    final event = widget.event;
    final fields = _fields();
    if (event != null) {
      fields.removeWhere((key, value) => value == _initialFields[key]);
      if (fields.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (event == null) {
        await widget.service.createDraft(widget.organization.id, fields);
      } else {
        await widget.service.edit(event.id, fields);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on EventRequestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not save the event. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? value) =>
      value?.trim().isNotEmpty == true ? null : 'Enter a value.';

  Widget _field(
    TextEditingController controller,
    String label, {
    String? helper,
    String? Function(String?)? validate,
    TextInputType? keyboard,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: !_saving,
      maxLines: lines,
      keyboardType: keyboard,
      validator: validate,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
      ),
    ),
  );

  Widget _dropdown(
    String label,
    String selected,
    Map<String, String> options,
    ValueChanged<String> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: DropdownButtonFormField<String>(
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final option in options.entries)
          DropdownMenuItem(
            value: option.key,
            child: Text(option.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _saving
          ? null
          : (value) {
              if (value != null) {
                onChanged(value);
              }
            },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final create = widget.event == null;
    final active = widget.event?.status == 'active';
    return PopScope(
      canPop: !_saving,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.organization.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      create
                          ? 'Save a draft first. An owner or admin can publish it when it’s ready.'
                          : 'Update the event details below.',
                    ),
                    const SizedBox(height: 24),
                    _field(_title, 'Event title', validate: _required),
                    _field(
                      _description,
                      'Description',
                      helper: active
                          ? null
                          : 'Add a description before publishing.',
                      lines: 3,
                      validate: active && _initialFields['description'] != ''
                          ? _required
                          : null,
                    ),
                    _dropdown(
                      'Category',
                      _category,
                      _categories,
                      (value) => setState(() => _category = value),
                    ),
                    _dropdown('City', _city, _cities, (value) {
                      if (value == _city) return;
                      setState(() {
                        _city = value;
                        _timezone = _timezones[value]!;
                        _error = null;
                      });
                    }),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.calendar_today_outlined),
                      title: const Text('Starts'),
                      subtitle: Text(
                        formatOrganizerEventTime(_start, _timezone),
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: _saving ? null : () => _pickTime(false),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule),
                      title: const Text('Ends (optional)'),
                      subtitle: Text(
                        _end == null
                            ? 'Add an end time'
                            : formatOrganizerEventTime(_end!, _timezone),
                      ),
                      onTap: _saving ? null : () => _pickTime(true),
                      trailing: _end == null
                          ? const Icon(Icons.add)
                          : IconButton(
                              tooltip: 'Clear end time',
                              onPressed: _saving
                                  ? null
                                  : () => setState(() {
                                      _end = null;
                                      _error = null;
                                    }),
                              icon: const Icon(Icons.close),
                            ),
                    ),
                    const SizedBox(height: 12),
                    _field(_place, 'Meeting point', validate: _required),
                    _field(_address, 'Address (optional)'),
                    _field(
                      _capacity,
                      'Maximum participants (optional)',
                      helper: 'Leave blank for unlimited places.',
                      keyboard: TextInputType.number,
                      validate: (value) {
                        final input = value?.trim() ?? '';
                        if (input.isEmpty) return null;
                        final capacity = int.tryParse(input, radix: 10);
                        return capacity == null ||
                                capacity < 1 ||
                                capacity > 2147483647
                            ? 'Enter a positive whole number.'
                            : null;
                      },
                    ),
                    _field(
                      _cover,
                      'Cover image URL (optional)',
                      keyboard: TextInputType.url,
                      validate: (value) {
                        final input = _optional(value ?? '');
                        if (input == null ||
                            input == widget.event?.coverImageUrl?.trim()) {
                          return null;
                        }
                        final uri = Uri.tryParse(input);
                        return uri?.scheme == 'https' && uri!.host.isNotEmpty
                            ? null
                            : 'Enter an HTTPS image URL.';
                      },
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(
                        _saving
                            ? 'Saving…'
                            : create
                            ? 'Save draft'
                            : 'Save changes',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
