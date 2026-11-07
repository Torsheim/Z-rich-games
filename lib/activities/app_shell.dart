import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../friends/friend_service.dart';
import 'activity.dart';
import 'activity_service.dart';
import 'activity_detail.dart';
import 'create_activity_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.userId,
    required this.username,
    required this.profile,
    required this.activities,
    this.friends,
  });
  final String userId, username;
  final Widget profile;
  final ActivityService activities;
  final FriendService? friends;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late List<Activity> _examples;
  List<Activity> _real = [];
  bool _showExamples = true, _loading = true;
  int _selected = 0, _sequence = 0, _createRevision = 0;
  String? _loadError;
  RealtimeChannel? _channel;
  @override
  void initState() {
    super.initState();
    _examples = exampleActivities(widget.userId);
    if (widget.friends?.pendingToken != null) _selected = 3;
    widget.friends?.addListener(_friendLink);
    WidgetsBinding.instance.addObserver(this);
    _channel = widget.activities.watch(() => unawaited(_load()));
    unawaited(_load());
  }

  void _selectTab(int index) {
    setState(() {
      _selected = index;
      if (index == 1) _createRevision++;
    });
  }

  void _friendLink() {
    if (mounted && widget.friends?.pendingToken != null) {
      setState(() => _selected = 3);
    }
  }

  @override
  void dispose() {
    widget.friends?.removeListener(_friendLink);
    WidgetsBinding.instance.removeObserver(this);
    if (_channel != null) {
      unawaited(widget.activities.client.removeChannel(_channel!));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final sequence = ++_sequence;
    try {
      final rows = await widget.activities.feed();
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _real = rows
            .map((a) => a.withData({'is_host': a.creator == widget.userId}))
            .toList();
        _loadError = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted && sequence == _sequence) {
        setState(() {
          _loading = false;
          _loadError = 'Could not refresh activities. Your last loaded plans are still here.';
        });
      }
    }
  }

  void _replace(Activity activity) {
    setState(() {
      final target = activity.demo ? _examples : _real;
      final index = target.indexWhere((a) => a.id == activity.id);
      if (index >= 0) {
        target[index] = activity;
      } else {
        target.insert(0, activity);
      }
    });
  }

  Future<Activity> _respond(Activity a, String response) async {
    final status = a.demo
        ? (response == 'decline'
              ? 'cancelled'
              : a.policy == 'approval_required' && a.invitation == null
              ? 'requested'
              : 'confirmed')
        : await widget.activities.respond(a.id, response);
    final next = a.withData({
      'my_status': status,
      'invite_status': a.invitation == null
          ? null
          : response == 'decline'
          ? 'declined'
          : 'accepted',
      'participant_count':
          a.count +
          (a.myStatus == 'confirmed' && status != 'confirmed'
              ? -1
              : a.myStatus != 'confirmed' && status == 'confirmed'
              ? 1
              : 0),
    });
    if (mounted) {
      _replace(next);
      if (!a.demo) unawaited(_load());
    }
    return next;
  }

  Future<Activity> _publish(
    Activity a,
    String visibility,
    String policy,
  ) async {
    if (!a.demo) await widget.activities.publish(a.id, visibility, policy);
    final next = a.withData({
      'visibility': visibility,
      'join_policy': policy,
      'status': 'active',
    });
    if (mounted) {
      _replace(next);
      if (!a.demo) unawaited(_load());
    }
    return next;
  }

  Future<void> _review(Activity a, String userId, bool approve) async {
    await widget.activities.review(a.id, userId, approve);
    if (mounted) unawaited(_load());
  }

  Future<void> _create(
    Map<String, dynamic> details,
    List<String> invited,
  ) async {
    final id = await widget.activities.create(details, invited);
    if (!mounted) return;
    _replace(
      Activity({
        ...details,
        'id': id,
        'created_by_user_id': widget.userId,
        'host_username': widget.username,
        'participant_count': 1,
        'my_status': 'confirmed',
        'invite_status': null,
        'is_host': true,
      }),
    );
    setState(() {
      _selected = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          details['status'] == 'draft'
              ? 'Draft saved. Only you can see it.'
              : 'Activity created. Your invitations are ready.',
        ),
      ),
    );
    unawaited(_load());
  }

  void _open(Activity a) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ActivityDetail(
          activity: a,
          service: widget.activities,
          onRespond: _respond,
          onPublish: _publish,
          onReview: _review,
        ),
      ),
    );
  }

  List<Activity> get _all =>
      [..._real, ...(_showExamples ? _examples : <Activity>[])]
        ..sort((a, b) => a.start.compareTo(b.start));
  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _selected,
      children: [
        _home(),
        CreateActivityScreen(
          friends: widget.friends,
          onCreate: _create,
          revision: _createRevision,
        ),
        _search(),
        widget.profile,
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selected,
      onDestinationSelected: _selectTab,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.add_circle_outline),
          selectedIcon: Icon(Icons.add_circle),
          label: 'Create',
        ),
        NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    ),
  );
  Widget _search() {
    final publicPlans = _all
        .where(
          (a) =>
              a.visibility == 'public' &&
              a.data['is_host'] != true &&
              a.myStatus != 'confirmed' &&
              a.state == 'active',
        )
        .toList();
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Around you',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Public plans, whenever you feel like meeting someone new.',
                      style: TextStyle(color: Color(0xFF64736D)),
                    ),
                    const SizedBox(height: 28),
                    if (_loadError != null) _refreshError(),
                    if (publicPlans.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text('No public plans here yet.'),
                      ),
                    ...publicPlans.map((a) => _planRow(a, public: true)),
                    const SizedBox(height: 32),
                    const Text(
                      'Search and filters will come later.',
                      style: TextStyle(fontSize: 12, color: Colors.black45),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Show example plans',
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Previews only. No real invitations are sent.',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: _showExamples,
                      onChanged: (value) =>
                          setState(() => _showExamples = value),
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

  Widget _home() {
    final all = _all;
    final invitations =
        all
            .where(
              (a) =>
                  a.invitation != null && a.myStatus != 'confirmed' && a.open,
            )
            .toList()
          ..sort(
            (a, b) => (a.invitation == 'pending' ? 0 : 1).compareTo(
              b.invitation == 'pending' ? 0 : 1,
            ),
          );
    final pending = invitations.where((a) => a.invitation == 'pending').length;
    final plans = all
        .where((a) => a.myStatus == 'confirmed' && a.state == 'active')
        .toList();
    final drafts = all
        .where((a) => a.data['is_host'] == true && a.state == 'draft')
        .toList();
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            pending > 0 ? 'New invitations' : 'Invitations',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (pending > 0)
                          Text(
                            '$pending new',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF64736D),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (invitations.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 20),
                        child: Text(
                          'You’re all caught up.',
                          style: TextStyle(color: Color(0xFF64736D)),
                        ),
                      )
                    else
                      SizedBox(
                        height: 154,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: invitations.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (context, index) =>
                              _invitationCard(invitations[index]),
                        ),
                      ),
                    const SizedBox(height: 32),
                    Text(
                      'Upcoming',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    if (_loading) const LinearProgressIndicator(),
                    if (_loadError != null) _refreshError(),
                    if (plans.isEmpty && !_loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'Nothing planned yet. Start something with your friends in Create.',
                          style: TextStyle(color: Color(0xFF64736D)),
                        ),
                      ),
                    ...plans.map((a) => _planRow(a)),
                    if (drafts.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(
                            'Drafts · ${drafts.length}',
                            style: const TextStyle(fontSize: 14),
                          ),
                          children: drafts.map((a) => _planRow(a)).toList(),
                        ),
                      ),
                    if (_showExamples)
                      const Padding(
                        padding: EdgeInsets.only(top: 24),
                        child: Text(
                          'Example plans are marked as previews.',
                          style: TextStyle(fontSize: 11, color: Colors.black45),
                        ),
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

  Widget _refreshError() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _loadError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        TextButton(onPressed: _load, child: const Text('Try again')),
      ],
    ),
  );

  Widget _invitationCard(Activity a) => SizedBox(
    width: 164,
    child: Material(
      color: const Color(0xFFEAF1EC),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _open(a),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 19,
                backgroundColor: Colors.white,
                child: Text(
                  a.host.substring(0, 1).toUpperCase(),
                  style: const TextStyle(color: Color(0xFF196C5D)),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                a.host,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              Text(
                a.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF64736D)),
              ),
              const Spacer(),
              Text(
                a.invitation == 'pending'
                    ? (a.demo ? 'Invited you · Example' : 'Invited you')
                    : 'Not going · tap to change',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Color(0xFF64736D)),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _planRow(Activity a, {bool public = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(a),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: categoryColor(a.category).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  categoryIcon(a.category),
                  size: 21,
                  color: categoryColor(a.category),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      a.when,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64736D),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      a.place,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64736D),
                      ),
                    ),
                    if (a.data['is_host'] == true || a.demo || public)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          [
                            if (a.data['is_host'] == true) 'You’re hosting',
                            if (public) a.attendance,
                            if (a.demo) 'Example',
                          ].join(' · '),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.black45,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
