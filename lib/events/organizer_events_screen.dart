import 'package:flutter/material.dart';

import 'event_service.dart';
import 'organizer_event_form.dart';

class OrganizerEventsScreen extends StatefulWidget {
  const OrganizerEventsScreen({super.key, required this.service});

  final EventService service;

  @override
  State<OrganizerEventsScreen> createState() => _OrganizerEventsScreenState();
}

typedef _OrganizerEvents = ({
  List<EventOrganization> organizations,
  EventOrganization? selected,
  List<EventActivity> events,
});

class _OrganizerEventsScreenState extends State<OrganizerEventsScreen> {
  late Future<_OrganizerEvents> _events;
  String? _selectedId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _events = _load(null);
  }

  Future<_OrganizerEvents> _load(String? id) async {
    final organizations = await widget.service.organizations();
    if (organizations.isEmpty) {
      return (
        organizations: organizations,
        selected: null,
        events: <EventActivity>[],
      );
    }
    final selected = organizations.firstWhere(
      (item) => item.id == id,
      orElse: () => organizations.first,
    );
    final events = await widget.service.managedEvents(selected.id);
    return (organizations: organizations, selected: selected, events: events);
  }

  Future<void> _reload([String? id]) async {
    final selectedId = id ?? _selectedId;
    final pending = _load(selectedId);
    setState(() {
      _selectedId = selectedId;
      _events = pending;
    });
    try {
      await pending;
    } catch (_) {
      // The FutureBuilder shows the error and retry action.
    }
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openForm(
    EventOrganization organization, [
    EventActivity? event,
  ]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => OrganizerEventForm(
          service: widget.service,
          organization: organization,
          event: event,
        ),
      ),
    );
    if (!mounted || saved != true) return;
    _notice(event == null ? 'Draft saved.' : 'Event updated.');
    await _reload(organization.id);
  }

  Future<void> _save(
    EventActivity event,
    Future<void> Function() action, {
    required String success,
    required String failure,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await action();
      if (!mounted) return;
      _notice(success);
      await _reload(event.organizationId);
    } on EventRequestException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice(failure);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _publish(EventActivity event) async {
    if (event.description?.trim().isNotEmpty != true) {
      _notice('Add a description before publishing.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Publish event?'),
        content: Text(
          '“${event.title}” will appear in Events. Signed-in users can join instantly.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep draft'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Publish event'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _save(
      event,
      () => widget.service.publish(event.id),
      success: 'Event published.',
      failure: 'Could not publish the event. Your draft is still saved.',
    );
  }

  Future<void> _cancel(EventActivity event) async {
    var reason = '';
    final confirmedReason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Cancel event?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('“${event.title}” will be marked as cancelled.'),
            const SizedBox(height: 16),
            TextField(
              minLines: 2,
              maxLines: 4,
              maxLength: 500,
              onChanged: (value) => reason = value,
              decoration: const InputDecoration(
                labelText: 'Public reason (optional)',
                helperText: 'This message appears on the event page.',
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep event'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, reason.trim()),
            child: const Text('Confirm cancellation'),
          ),
        ],
      ),
    );
    if (!mounted || confirmedReason == null) return;
    await _save(
      event,
      () => widget.service.cancel(
        event.id,
        reason: confirmedReason.isEmpty ? null : confirmedReason,
      ),
      success: 'Event cancelled.',
      failure: 'Could not cancel the event. Try again.',
    );
  }

  void _openRoster(EventActivity event) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _EventRoster(service: widget.service, event: event),
      ),
    );
  }

  Widget _card(
    EventActivity event,
    EventOrganization organization,
    bool disabled,
  ) {
    final theme = Theme.of(context);
    final draft = event.status == 'draft';
    final active = event.status == 'active';
    final manage = organization.canPublish;
    final label = switch (event.status) {
      'draft' => 'Draft',
      'active' => 'Published',
      'cancelled' => 'Cancelled',
      'completed' => 'Completed',
      _ => event.status,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Chip(label: Text(label)),
            const SizedBox(height: 8),
            Text(event.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(formatOrganizerEventTime(event.startsAt, event.timezone)),
            Text('${event.placeName} · ${event.cityName}'),
            if (event.cancellationReason?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(event.cancellationReason!),
            ],
            if (draft || manage) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (draft || (active && manage))
                    OutlinedButton.icon(
                      onPressed: disabled
                          ? null
                          : () => _openForm(organization, event),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit event'),
                    ),
                  if (draft && manage)
                    OutlinedButton.icon(
                      onPressed: disabled ? null : () => _publish(event),
                      icon: const Icon(Icons.public),
                      label: const Text('Publish draft'),
                    ),
                  if (!draft && manage)
                    OutlinedButton.icon(
                      onPressed: disabled ? null : () => _openRoster(event),
                      icon: const Icon(Icons.groups_outlined),
                      label: const Text('Confirmed participants'),
                    ),
                  if (active && manage)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: disabled ? null : () => _cancel(event),
                      child: const Text('Cancel event'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Organizer events')),
    body: SafeArea(
      child: FutureBuilder<_OrganizerEvents>(
        future: _events,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          if (loading && !snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(
                semanticsLabel: 'Loading events',
              ),
            );
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            return _OrganizerMessage(
              title: 'Could not load organizer events',
              detail: error is EventRequestException
                  ? error.message
                  : 'Check your connection and try again.',
              onRetry: _reload,
            );
          }
          final data = snapshot.data!;
          final selected = data.selected;
          if (selected == null) {
            return _OrganizerMessage(
              title: 'No organizer access yet',
              detail:
                  'A verified organization can add you to its organizer team.',
              onRetry: _reload,
              actionLabel: 'Refresh',
            );
          }
          final disabled = loading || _saving;
          return RefreshIndicator(
            onRefresh: () =>
                disabled ? Future<void>.value() : _reload(selected.id),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButtonFormField<String>(
                          key: ValueKey(selected.id),
                          initialValue: selected.id,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Verified organization',
                          ),
                          items: [
                            for (final item in data.organizations)
                              DropdownMenuItem(
                                value: item.id,
                                child: Text(
                                  item.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: disabled
                              ? null
                              : (id) {
                                  if (id != null && id != selected.id) {
                                    _reload(id);
                                  }
                                },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          selected.canPublish
                              ? 'Create drafts and publish them when they’re ready.'
                              : 'Create and edit drafts for an owner or admin to publish.',
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: disabled
                              ? null
                              : () => _openForm(selected),
                          icon: const Icon(Icons.add),
                          label: const Text('Create event draft'),
                        ),
                        const SizedBox(height: 20),
                        if (disabled)
                          const LinearProgressIndicator(
                            semanticsLabel: 'Updating events',
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Managed events',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Refresh events',
                              onPressed: disabled
                                  ? null
                                  : () => _reload(selected.id),
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                        if (data.events.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              'Your organization’s drafts and events will appear here.',
                            ),
                          ),
                        for (final event in data.events)
                          _card(event, selected, disabled),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _EventRoster extends StatefulWidget {
  const _EventRoster({required this.service, required this.event});

  final EventService service;
  final EventActivity event;

  @override
  State<_EventRoster> createState() => _EventRosterState();
}

class _EventRosterState extends State<_EventRoster> {
  late Future<List<EventParticipant>> _participants;

  @override
  void initState() {
    super.initState();
    _participants = widget.service.participants(widget.event.id);
  }

  void _reload() {
    setState(
      () => _participants = widget.service.participants(widget.event.id),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Confirmed participants'),
      actions: [
        IconButton(
          tooltip: 'Refresh participants',
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: FutureBuilder<List<EventParticipant>>(
        future: _participants,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(
                semanticsLabel: 'Loading participants',
              ),
            );
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            return _OrganizerMessage(
              title: 'Could not load participants',
              detail: error is EventRequestException
                  ? error.message
                  : 'Check your connection and try again.',
              onRetry: _reload,
            );
          }
          final roster = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.event.title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        roster.isEmpty
                            ? 'Confirmed participants will appear here.'
                            : '${roster.length} confirmed',
                      ),
                      const SizedBox(height: 16),
                      for (final person in roster)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            child: Icon(Icons.person_outline),
                          ),
                          title: Text(person.username),
                          subtitle: Text(
                            formatOrganizerEventTime(
                              person.confirmedAt,
                              widget.event.timezone,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _OrganizerMessage extends StatelessWidget {
  const _OrganizerMessage({
    required this.title,
    required this.detail,
    required this.onRetry,
    this.actionLabel = 'Try again',
  });

  final String title, detail, actionLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(detail, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: Text(actionLabel)),
          ],
        ),
      ),
    ),
  );
}
