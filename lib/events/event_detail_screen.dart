import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import 'event_service.dart';

String formatEventDate(DateTime instant, String timezone) {
  final local = tz.timeZoneDatabase.locations.containsKey(timezone)
      ? tz.TZDateTime.from(instant, tz.getLocation(timezone))
      : instant.toUtc();
  return '${DateFormat('EEE, d MMM yyyy · HH:mm', 'en').format(local)} ${local.timeZoneName}';
}

class EventDetailScreen extends StatefulWidget {
  const EventDetailScreen({
    super.key,
    required this.service,
    required this.activityId,
    required this.signedIn,
    this.onSignIn,
  });

  final EventService service;
  final String activityId;
  final bool signedIn;
  final VoidCallback? onSignIn;

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen>
    with WidgetsBindingObserver {
  EventActivity? _event;
  String? _participation;
  String? _loadError;
  String? _actionError;
  bool _loading = true;
  bool _saving = false;
  int _loadRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant EventDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activityId != oldWidget.activityId ||
        widget.signedIn != oldWidget.signedIn ||
        widget.service != oldWidget.service) {
      _event = null;
      _participation = null;
      _actionError = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_saving) unawaited(_load());
  }

  Future<void> _load() async {
    final revision = ++_loadRevision;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait<Object?>([
        widget.service.getEvent(widget.activityId),
        if (widget.signedIn) widget.service.myParticipation(widget.activityId),
      ]);
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _event = results.first as EventActivity?;
        _participation = results.length == 2 ? results[1] as String? : null;
      });
    } catch (_) {
      if (mounted && revision == _loadRevision) {
        setState(() => _loadError = 'Could not refresh this event.');
      }
    } finally {
      if (mounted && revision == _loadRevision) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _changeParticipation({required bool join}) async {
    if (_saving) return;
    final id = widget.activityId;
    final service = widget.service;
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      if (join) {
        await service.join(id);
      } else {
        await service.leave(id);
      }
      if (!mounted || id != widget.activityId || !widget.signedIn) return;
      setState(() => _participation = join ? 'confirmed' : 'cancelled');
      await _load();
    } catch (error) {
      if (!mounted || id != widget.activityId || !widget.signedIn) return;
      setState(() {
        _actionError = switch (error) {
          EventRequestException(:final message) => message,
          _ =>
            join
                ? 'Could not join this event. Please try again.'
                : 'Could not leave this event. Please try again.',
        };
      });
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyEventLink(Uri link) async {
    var message = 'Event link copied.';
    try {
      await Clipboard.setData(ClipboardData(text: link.toString()));
    } catch (_) {
      message = 'Could not copy the event link.';
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = _event;
    return Scaffold(
      appBar: AppBar(title: const Text('Event')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _saving ? () async {} : _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loading)
                        const LinearProgressIndicator(
                          semanticsLabel: 'Loading event',
                        ),
                      if (_loadError != null)
                        Card(
                          child: ListTile(
                            title: Text(_loadError!),
                            trailing: TextButton(
                              onPressed: _loading || _saving ? null : _load,
                              child: const Text('Retry'),
                            ),
                          ),
                        ),
                      if (event != null)
                        _buildEvent(context, event)
                      else if (!_loading && _loadError == null)
                        const Card(
                          child: ListTile(
                            leading: Icon(Icons.event_busy_outlined),
                            title: Text('Event unavailable'),
                            subtitle: Text(
                              'This link may point to an event that is no longer public.',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEvent(BuildContext context, EventActivity event) {
    final theme = Theme.of(context);
    final cancelled = event.status == 'cancelled' || event.cancelledAt != null;
    final started = !event.startsAt.isAfter(DateTime.now());
    final upcoming = event.status == 'active' && !cancelled && !started;
    final acceptsJoin =
        upcoming &&
        event.visibility == 'public' &&
        event.joinPolicy == 'instant';
    final places = event.availablePlaces;
    final full = places != null && places <= 0;
    final canLeave = switch (_participation) {
      'confirmed' || 'requested' || 'waitlisted' => true,
      _ => false,
    };
    final cannotRejoin =
        _participation == 'removed' || _participation == 'rejected';
    final status = switch (_participation) {
      'confirmed' => 'Going',
      'requested' => 'Request pending',
      'waitlisted' => 'Waitlisted',
      'cancelled' => 'Not going',
      'rejected' => 'Request declined',
      'removed' => 'Participation removed',
      _ => null,
    };
    final reason = event.cancellationReason;
    final cover = event.coverImageUrl;
    final busy = _loading || _saving;
    final link =
        event.visibility == 'public' && (event.status == 'active' || cancelled)
        ? widget.service.eventLink(event.id)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (cover != null && cover.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.network(
                cover,
                width: double.infinity,
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            Chip(
              avatar: const Icon(Icons.local_activity_outlined, size: 18),
              label: Text(event.categoryName),
            ),
            Chip(
              avatar: const Icon(Icons.place_outlined, size: 18),
              label: Text(event.cityName),
            ),
            if (cancelled)
              Chip(
                label: const Text('Cancelled'),
                backgroundColor: theme.colorScheme.errorContainer,
              )
            else if (status != null && widget.signedIn)
              Chip(label: Text(status)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          event.title,
          style: theme.textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 8),
        Text('Organized by ${event.organizationName}'),
        if (link != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _copyEventLink(link),
              icon: const Icon(Icons.link),
              label: const Text('Copy event link'),
            ),
          ),
        const SizedBox(height: 20),
        if (cancelled)
          Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.event_busy_outlined),
              title: const Text('This event was cancelled.'),
              subtitle: reason == null || reason.trim().isEmpty
                  ? null
                  : Text(reason),
            ),
          ),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.calendar_today_outlined),
                title: Text(formatEventDate(event.startsAt, event.timezone)),
                subtitle: event.endsAt == null
                    ? null
                    : Text(
                        'Ends ${formatEventDate(event.endsAt!, event.timezone)}',
                      ),
              ),
              ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(event.placeName),
                subtitle: event.address?.trim().isNotEmpty == true
                    ? Text(event.address!)
                    : null,
              ),
              ListTile(
                leading: const Icon(Icons.people_outline),
                title: Text(switch (places) {
                  0 => 'Currently full',
                  1 => '1 place available',
                  int count => '$count places available',
                  null =>
                    event.maxParticipants == null
                        ? 'No participant limit'
                        : 'Capacity ${event.maxParticipants}',
                }),
              ),
            ],
          ),
        ),
        if (event.description?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 16),
          Text(event.description!),
        ],
        const SizedBox(height: 24),
        if (_actionError != null) ...[
          Text(_actionError!, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 12),
        ],
        if (_saving)
          const LinearProgressIndicator(semanticsLabel: 'Saving participation'),
        if (!cancelled && started && event.status == 'active')
          const Text('This event has already started.'),
        if (widget.signedIn && upcoming && canLeave)
          OutlinedButton.icon(
            onPressed: busy ? null : () => _changeParticipation(join: false),
            icon: const Icon(Icons.exit_to_app_outlined),
            label: Text(
              _participation == 'requested'
                  ? 'Withdraw request'
                  : 'Leave event',
            ),
          )
        else if (widget.signedIn && acceptsJoin && !cannotRejoin)
          FilledButton.icon(
            onPressed: busy || full || _loadError != null
                ? null
                : () => _changeParticipation(join: true),
            icon: const Icon(Icons.how_to_reg_outlined),
            label: Text(full ? 'Currently full' : 'Join event'),
          )
        else if (!widget.signedIn && acceptsJoin && !full)
          if (widget.onSignIn case final onSignIn?)
            FilledButton(
              onPressed: onSignIn,
              child: const Text('Sign in to join'),
            )
          else
            const Text('Sign in to join this event.'),
        if (upcoming && event.joinPolicy != 'instant' && !canLeave)
          const Text('This event does not offer direct sign-up.'),
      ],
    );
  }
}
