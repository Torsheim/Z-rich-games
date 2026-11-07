import 'dart:async';

import 'package:flutter/material.dart';

import 'event_detail_screen.dart';
import 'event_service.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({
    super.key,
    required this.service,
    required this.signedIn,
    this.onSignIn,
    this.onEventSignIn,
    this.onManage,
  });

  final EventService service;
  final bool signedIn;
  final VoidCallback? onSignIn;
  final ValueChanged<String>? onEventSignIn;
  final VoidCallback? onManage;

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen>
    with WidgetsBindingObserver {
  EventCatalog? _catalog;
  List<EventActivity> _events = [];
  EventActivity? _cursor;
  String? _city;
  String? _category;
  String? _error;
  bool _filterError = false;
  bool _loading = true;
  bool _loadingMore = false;
  int _unread = 0;
  int _revision = 0;
  int _inboxRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant EventsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.signedIn != widget.signedIn) {
      _unread = 0;
      unawaited(_loadUnread());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    await Future.wait([
      _loadEvents(),
      if (_catalog == null) _loadFilters(),
      _loadUnread(),
    ]);
  }

  Future<void> _loadFilters() async {
    try {
      final result = await widget.service.catalog();
      if (!mounted) return;
      setState(() {
        _catalog = result;
        _filterError = false;
      });
    } catch (_) {
      if (mounted && _catalog == null) setState(() => _filterError = true);
    }
  }

  Future<void> _loadEvents({bool more = false, bool reset = false}) async {
    if (more && (_loading || _loadingMore || _cursor == null)) return;
    final revision = ++_revision;
    final after = more ? _cursor : null;
    setState(() {
      _error = null;
      _loading = !more;
      _loadingMore = more;
      if (reset) {
        _events = [];
        _cursor = null;
      }
    });
    try {
      final page = await widget.service.listEvents(
        cityId: _city,
        categoryId: _category,
        after: after,
      );
      if (!mounted || revision != _revision) return;
      setState(() {
        _events = {
          if (more)
            for (final event in _events) event.id: event,
          for (final event in page) event.id: event,
        }.values.toList();
        _cursor = page.length == EventService.pageSize ? page.last : null;
      });
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(
          () => _error = more
              ? 'Could not load more events.'
              : 'Could not refresh events.',
        );
      }
    } finally {
      if (mounted && revision == _revision) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _loadUnread() async {
    final revision = ++_inboxRevision;
    if (!widget.signedIn) return;
    try {
      final updates = await widget.service.updates();
      if (mounted && revision == _inboxRevision) {
        setState(
          () =>
              _unread = updates.where((update) => update.readAt == null).length,
        );
      }
    } catch (_) {
      // Opening the inbox offers a retry for failed reads.
    }
  }

  Future<void> _openEvent(String id) async {
    final eventSignIn = widget.onEventSignIn;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EventDetailScreen(
          service: widget.service,
          activityId: id,
          signedIn: widget.signedIn,
          onSignIn: eventSignIn == null
              ? widget.onSignIn
              : () => eventSignIn(id),
        ),
      ),
    );
    if (mounted) await _loadEvents();
  }

  Future<void> _openInbox() async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _UpdatesDialog(service: widget.service),
    );
    if (!mounted || !widget.signedIn) return;
    unawaited(_loadUnread());
    if (id != null) await _openEvent(id);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final theme = Theme.of(context);
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Events',
                            style: theme.textTheme.headlineLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Refresh events',
                          onPressed: _loading ? null : _refresh,
                          icon: const Icon(Icons.refresh),
                        ),
                        if (widget.signedIn)
                          Badge(
                            isLabelVisible: _unread > 0,
                            label: Text('$_unread'),
                            child: IconButton(
                              tooltip: 'Event updates',
                              onPressed: _openInbox,
                              icon: const Icon(Icons.notifications_outlined),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Browse upcoming public events from local organizers.',
                    ),
                    if (widget.signedIn && widget.onManage != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: widget.onManage,
                          icon: const Icon(Icons.edit_calendar_outlined),
                          label: const Text('Manage events'),
                        ),
                      ),
                    if (!widget.signedIn && widget.onSignIn != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: widget.onSignIn,
                          icon: const Icon(Icons.login),
                          label: const Text('Sign in'),
                        ),
                      ),
                    const SizedBox(height: 20),
                    if (catalog != null)
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _filter(
                            label: 'City',
                            all: 'All cities',
                            value: _city,
                            options: {
                              for (final city in catalog.cities)
                                city.id: city.name,
                            },
                            onChanged: (id) {
                              _city = id;
                              unawaited(_loadEvents(reset: true));
                            },
                          ),
                          _filter(
                            label: 'Category',
                            all: 'All categories',
                            value: _category,
                            options: {
                              for (final category in catalog.categories)
                                category.id: category.name,
                            },
                            onChanged: (id) {
                              _category = id;
                              unawaited(_loadEvents(reset: true));
                            },
                          ),
                        ],
                      ),
                    if (_filterError)
                      _errorCard('Filters could not load.', _loadFilters),
                    const SizedBox(height: 14),
                    if (_loading)
                      const LinearProgressIndicator(
                        semanticsLabel: 'Loading events',
                      ),
                    if (_error != null) _errorCard(_error!, _refresh),
                    if (_events.isEmpty && !_loading && _error == null)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.event_available_outlined),
                          title: const Text('No upcoming events'),
                          subtitle: Text(
                            _city == null && _category == null
                                ? 'New public events will appear here.'
                                : 'Try a different city or category.',
                          ),
                        ),
                      ),
                    for (final event in _events)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                          leading: const Icon(Icons.event_outlined),
                          title: Text(
                            event.title,
                            style: theme.textTheme.titleLarge,
                          ),
                          subtitle: Text(
                            '${event.categoryName} · ${event.cityName}\n'
                            '${formatEventDate(event.startsAt, event.timezone)} · ${event.placeName}\n'
                            'Organized by ${event.organizationName}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openEvent(event.id),
                        ),
                      ),
                    if (_cursor != null)
                      OutlinedButton.icon(
                        onPressed: _loading || _loadingMore
                            ? null
                            : () => _loadEvents(more: true),
                        icon: const Icon(Icons.expand_more),
                        label: Text(_loadingMore ? 'Loading…' : 'Load more'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filter({
    required String label,
    required String all,
    required String? value,
    required Map<String, String> options,
    required ValueChanged<String?> onChanged,
  }) => SizedBox(
    width: 218,
    child: DropdownButtonFormField<String>(
      initialValue: value ?? '',
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(value: '', child: Text(all)),
        for (final option in options.entries)
          DropdownMenuItem(
            value: option.key,
            child: Text(option.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (id) => onChanged(id == '' ? null : id),
    ),
  );
}

Widget _errorCard(String message, VoidCallback retry) => Card(
  child: ListTile(
    title: Text(message),
    trailing: TextButton(onPressed: retry, child: const Text('Retry')),
  ),
);

class _UpdatesDialog extends StatefulWidget {
  const _UpdatesDialog({required this.service});

  final EventService service;

  @override
  State<_UpdatesDialog> createState() => _UpdatesDialogState();
}

class _UpdatesDialogState extends State<_UpdatesDialog> {
  late Future<List<EventUpdate>> _updates;
  final _read = <String>{};
  final _saving = <String>{};
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _updates = widget.service.updates();
  }

  Future<void> _mark(EventUpdate update, {bool open = false}) async {
    if (_saving.contains(update.id)) return;
    if (update.readAt == null && !_read.contains(update.id)) {
      setState(() {
        _error = false;
        _saving.add(update.id);
      });
      try {
        await widget.service.markUpdateRead(update.id);
        if (!mounted) return;
        setState(() => _read.add(update.id));
      } catch (_) {
        if (!mounted) return;
        setState(() => _error = true);
        return;
      } finally {
        if (mounted) setState(() => _saving.remove(update.id));
      }
    }
    if (open && mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context, update.activityId);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 560,
      height: MediaQuery.sizeOf(context).height * .66,
      child: Column(
        children: [
          ListTile(
            title: Text(
              'Event updates',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            trailing: IconButton(
              tooltip: 'Close updates',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          if (_error)
            const Text('Could not mark the update as read. Try again.'),
          Expanded(
            child: FutureBuilder<List<EventUpdate>>(
              future: _updates,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _errorCard('Could not load updates.', () {
                    setState(() => _updates = widget.service.updates());
                  });
                }
                final updates = snapshot.data ?? [];
                if (updates.isEmpty) {
                  return const Center(child: Text('You’re all caught up.'));
                }
                return ListView.separated(
                  itemCount: updates.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, index) => _tile(updates[index]),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  Widget _tile(EventUpdate update) {
    final unread = update.readAt == null && !_read.contains(update.id);
    final cancelled = update.kind == 'cancelled';
    final reason = update.cancellationReason;
    final changed = switch ((update.scheduleChanged, update.venueChanged)) {
      (true, true) => 'Time and venue changed',
      (true, false) => 'Time changed',
      (false, true) => 'Venue changed',
      _ => 'Event changed',
    };
    return ListTile(
      leading: Icon(
        cancelled ? Icons.event_busy_outlined : Icons.event_outlined,
      ),
      title: Text(
        update.title,
        style: unread ? const TextStyle(fontWeight: FontWeight.bold) : null,
      ),
      subtitle: Text(
        cancelled
            ? reason == null || reason.isEmpty
                  ? 'Event cancelled'
                  : 'Event cancelled · $reason'
            : '$changed\n${formatEventDate(update.startsAt, update.timezone)}\n${update.placeName}',
      ),
      onTap: _saving.contains(update.id)
          ? null
          : () => _mark(update, open: true),
      trailing: unread
          ? IconButton(
              tooltip: 'Mark update as read',
              onPressed: _saving.contains(update.id)
                  ? null
                  : () => _mark(update),
              icon: const Icon(Icons.mark_email_read_outlined),
            )
          : const Icon(Icons.chevron_right),
    );
  }
}
