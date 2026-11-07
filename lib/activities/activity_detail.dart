import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'activity.dart';
import 'activity_service.dart';

class ActivityDetail extends StatefulWidget {
  const ActivityDetail({
    super.key,
    required this.activity,
    required this.service,
    required this.onRespond,
    required this.onPublish,
    required this.onReview,
  });
  final Activity activity;
  final ActivityService service;
  final Future<Activity> Function(Activity, String) onRespond;
  final Future<Activity> Function(Activity, String, String) onPublish;
  final Future<void> Function(Activity, String, bool) onReview;
  @override
  State<ActivityDetail> createState() => _ActivityDetailState();
}

class _ActivityDetailState extends State<ActivityDetail> {
  late Activity _activity = widget.activity;
  Future<List<Map<String, dynamic>>>? _roster;
  bool _busy = false;
  String? _error;
  bool get _host => _activity.data['is_host'] == true;
  @override
  void initState() {
    super.initState();
    if (_host && !_activity.demo) _roster = widget.service.roster(_activity.id);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on PostgrestException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Unable to save the change. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _respond(String response) => _run(() async {
    final next = await widget.onRespond(_activity, response);
    if (mounted) setState(() => _activity = next);
  });
  Future<void> _visibility() async {
    var visibility = _activity.visibility == 'public'
        ? 'invite_only'
        : 'public';
    var policy = 'instant';
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: Text(
            visibility == 'public'
                ? 'Open this plan to the city?'
                : 'Make this plan private?',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                visibility == 'public'
                    ? 'Your description and meeting point become visible to other signed-in users. Existing friends and invitations stay in place.'
                    : 'Existing participants keep their places. New people need an invitation. Pending public requests will be declined.',
              ),
              if (visibility == 'public') ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: policy,
                  decoration: const InputDecoration(
                    labelText: 'New participants',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'instant',
                      child: Text('Join directly'),
                    ),
                    DropdownMenuItem(
                      value: 'approval_required',
                      child: Text('Request my approval'),
                    ),
                  ],
                  onChanged: (v) => update(() => policy = v!),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                visibility == 'public' ? 'Publish activity' : 'Make private',
              ),
            ),
          ],
        ),
      ),
    );
    if (yes != true || !mounted) return;
    await _run(() async {
      final next = await widget.onPublish(
        _activity,
        visibility,
        visibility == 'invite_only' ? 'invitation_required' : policy,
      );
      if (mounted) {
        final nextRoster = _host && !next.demo
            ? widget.service.roster(next.id)
            : null;
        setState(() {
          _activity = next;
          _roster = nextRoster;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = _activity;
    return Scaffold(
      appBar: AppBar(title: Text(a.demo ? 'Example activity' : 'Activity')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (a.demo)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Layout preview: changes to this example stay in this session and do not invite real people.',
                        ),
                      ),
                    ),
                  if (a.data['cover_image_url'] != null &&
                      (a.data['cover_image_url'] as String).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.network(
                          a.data['cover_image_url'] as String,
                          height: 180,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        label: Text(
                          activityCategories[a.category] ?? a.category,
                        ),
                        avatar: Icon(categoryIcon(a.category), size: 18),
                      ),
                      Chip(
                        label: Text(
                          a.visibility == 'public' ? 'Public' : 'Invite only',
                        ),
                      ),
                      Chip(
                        label: Text(
                          a.state == 'draft' ? 'Draft' : a.attendance,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    a.title,
                    style: Theme.of(context).textTheme.headlineLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Hosted by ${a.host}'),
                  const SizedBox(height: 24),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_today_outlined),
                    title: Text(a.when),
                    subtitle: Text(a.data['timezone'] as String),
                  ),
                  if (a.data['ends_at'] != null)
                    Text(
                      'Ends: ${Activity({...a.data, 'starts_at': a.data['ends_at']}).when}',
                    ),
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 16),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'MEETING POINT',
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            a.place,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if ((a.data['address'] ?? '')
                              .toString()
                              .isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(a.data['address'] as String),
                          ],
                          if (a.data['latitude'] != null)
                            Text(
                              '${a.data['latitude']}, ${a.data['longitude']}',
                            ),
                          TextButton.icon(
                            onPressed: () async {
                              try {
                                await Clipboard.setData(
                                  ClipboardData(
                                    text:
                                        '${a.place}\n${a.data['address'] ?? ''}',
                                  ),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Meeting point copied.'),
                                    ),
                                  );
                                }
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Unable to copy. You can select the address instead.',
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                            icon: const Icon(Icons.copy_outlined, size: 18),
                            label: const Text('Copy meeting point'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Text(a.data['description'] as String),
                  const SizedBox(height: 24),
                  Text(
                    a.limit == null
                        ? '${a.count} people going · no limit'
                        : '${a.count} of ${a.limit} places taken',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    a.policy == 'approval_required'
                        ? 'New participants need the host’s approval. Invited friends can join directly.'
                        : a.policy == 'invitation_required'
                        ? 'Only invited friends can join.'
                        : 'Anyone signed in can join while places are available.',
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  if (!_host && a.open) ...[
                    if (a.myStatus == 'confirmed' || a.myStatus == 'requested')
                      OutlinedButton(
                        onPressed: _busy ? null : () => _respond('decline'),
                        child: Text(
                          a.myStatus == 'requested'
                              ? 'Withdraw request'
                              : 'Change to not going',
                        ),
                      )
                    else ...[
                      FilledButton(
                        onPressed: _busy || a.full
                            ? null
                            : () => _respond('attend'),
                        child: Text(
                          a.full
                              ? 'Currently full'
                              : a.policy == 'approval_required' &&
                                    a.invitation == null
                              ? 'Request to join'
                              : a.invitation == 'declined' ||
                                    a.myStatus == 'cancelled'
                              ? 'Change to going'
                              : 'I’m going',
                        ),
                      ),
                      if (a.invitation == 'pending')
                        TextButton(
                          onPressed: _busy ? null : () => _respond('decline'),
                          child: const Text('Decline invitation'),
                        ),
                    ],
                  ],
                  if (_host && a.state == 'draft')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                final next = await widget.onPublish(
                                  a,
                                  a.visibility,
                                  a.policy,
                                );
                                if (mounted) setState(() => _activity = next);
                              }),
                        child: const Text(
                          'Activate activity & send invitations',
                        ),
                      ),
                    ),
                  if (_host && a.start.isAfter(DateTime.now()))
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _visibility,
                      icon: Icon(
                        a.visibility == 'public'
                            ? Icons.lock_outline
                            : Icons.public,
                      ),
                      label: Text(
                        a.visibility == 'public'
                            ? 'Make invite only'
                            : 'Publish publicly',
                      ),
                    ),
                  if (_host && _roster != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Your group',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    FutureBuilder<List<Map<String, dynamic>>>(
                      future: _roster,
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return TextButton(
                            onPressed: () {
                              final next = widget.service.roster(a.id);
                              setState(() {
                                _roster = next;
                              });
                            },
                            child: const Text('Retry group list'),
                          );
                        }
                        if (!snapshot.hasData) {
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: LinearProgressIndicator(),
                          );
                        }
                        return Column(
                          children: snapshot.data!
                              .map(
                                (p) => ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(p['username'] as String),
                                  subtitle: Text(p['status'] as String),
                                  trailing: p['status'] == 'requested'
                                      ? Wrap(
                                          children: [
                                            IconButton(
                                              tooltip:
                                                  'Approve ${p['username']}',
                                              onPressed: _busy
                                                  ? null
                                                  : () => _review(p, true),
                                              icon: const Icon(Icons.check),
                                            ),
                                            IconButton(
                                              tooltip:
                                                  'Decline ${p['username']}',
                                              onPressed: _busy
                                                  ? null
                                                  : () => _review(p, false),
                                              icon: const Icon(Icons.close),
                                            ),
                                          ],
                                        )
                                      : null,
                                ),
                              )
                              .toList(),
                        );
                      },
                    ),
                  ],
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Saving…'),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _review(Map<String, dynamic> person, bool approve) =>
      _run(() async {
        await widget.onReview(_activity, person['user_id'] as String, approve);
        if (!mounted) return;
        final next = widget.service.roster(_activity.id);
        setState(() {
          _roster = next;
          if (approve) {
            _activity = _activity.withData({
              'participant_count': _activity.count + 1,
            });
          }
        });
      });
}
