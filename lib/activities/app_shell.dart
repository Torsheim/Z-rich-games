import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../friends/friend_service.dart';
import '../events/event_service.dart';
import '../events/events_screen.dart';
import '../events/organizer_events_screen.dart';
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
    this.events,
  });
  final String userId, username;
  final Widget profile;
  final ActivityService activities;
  final FriendService? friends;
  final EventService? events;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late List<Activity> _examples;
  List<Activity> _real = [];
  bool _showExamples = true, _loading = true;
  int _selected = 0, _sequence = 0, _createRevision = 0, _eventsRevision = 0;
  String _filter = 'All';
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
      _filter = 'All';
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
        _events(),
        widget.profile,
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selected,
      onDestinationSelected: _selectTab,
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        const NavigationDestination(
          icon: Icon(Icons.add_circle_outline),
          selectedIcon: Icon(Icons.add_circle),
          label: 'Create',
        ),
        if (widget.events == null)
          const NavigationDestination(icon: Icon(Icons.search), label: 'Search')
        else
          const NavigationDestination(
            icon: Icon(Icons.event_outlined),
            selectedIcon: Icon(Icons.event),
            label: 'Events',
          ),
        const NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    ),
  );
  Widget _events() {
    final service = widget.events;
    if (service == null) return _search();
    return EventsScreen(
      key: ValueKey(_eventsRevision),
      service: service,
      signedIn: true,
      onManage: () => unawaited(_manageEvents(service)),
    );
  }

  Future<void> _manageEvents(EventService service) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => OrganizerEventsScreen(service: service),
    ));
    if (mounted) setState(() => _eventsRevision++);
  }

  Widget _search() => const SafeArea(
    child: Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.travel_explore, size: 54, color: Color(0xFF196C5D)),
            SizedBox(height: 24),
            Text(
              'Find your next plan',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 12),
            Text(
              'Search is coming next. For now, explore your suggestions on Home.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
  Widget _home() {
    final all = _all;
    final invitations = all
        .where(
          (a) =>
              a.invitation == 'pending' &&
              a.myStatus != 'confirmed' &&
              a.state == 'active',
        )
        .toList();
    final plans = all
        .where(
          (a) =>
              a.myStatus == 'confirmed' &&
              a.data['is_host'] != true &&
              a.state == 'active',
        )
        .toList();
    final hosting = all.where((a) => a.data['is_host'] == true).toList();
    final suggested = all
        .where(
          (a) =>
              a.visibility == 'public' &&
              a.data['is_host'] != true &&
              a.myStatus != 'confirmed' &&
              a.invitation == null,
        )
        .toList();
    final replies = all
        .where(
          (a) =>
              a.invitation == 'declined' ||
              (a.invitation != null && a.myStatus == 'cancelled'),
        )
        .toList();
    final next = plans.where((a) => a.open).firstOrNull;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.location_on_outlined,
                          size: 18,
                          color: Color(0xFF196C5D),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'ZURICH',
                          style: TextStyle(
                            letterSpacing: 2,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Refresh activities',
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                        ),
                        Badge(
                          isLabelVisible: invitations.isNotEmpty,
                          label: Text('${invitations.length}'),
                          child: IconButton(
                            tooltip: 'View invitations',
                            onPressed: () =>
                                setState(() => _filter = 'Invitations'),
                            icon: const Icon(Icons.mail_outline),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Text(
                      'Hello, ${widget.username}.',
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                          ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'A little less planning. A little more doing.',
                      style: TextStyle(color: Color(0xFF64736D), fontSize: 16),
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _summary(
                          '${invitations.length}',
                          'invitations',
                          Icons.mark_email_unread_outlined,
                          () => setState(() => _filter = 'Invitations'),
                        ),
                        _summary(
                          '${plans.length}',
                          'upcoming',
                          Icons.calendar_today_outlined,
                          () => setState(() => _filter = 'My plans'),
                        ),
                        _summary(
                          '${hosting.length}',
                          'hosting',
                          Icons.people_outline,
                          () => setState(() => _filter = 'My plans'),
                        ),
                      ],
                    ),
                    if (next != null && _filter == 'All') ...[
                      const SizedBox(height: 24),
                      InkWell(
                        onTap: () => _open(next),
                        borderRadius: BorderRadius.circular(24),
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: const Color(0xFF174C40),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'YOUR NEXT MEETUP',
                                      style: TextStyle(
                                        color: Color(0xFFBBDACD),
                                        fontSize: 11,
                                        letterSpacing: 1.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (next.demo)
                                    const Text(
                                      'EXAMPLE',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 10,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                next.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                next.when,
                                style: const TextStyle(color: Colors.white),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.place_outlined,
                                    color: Color(0xFFBBDACD),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      next.place,
                                      style: const TextStyle(
                                        color: Color(0xFFBBDACD),
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.arrow_forward,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: ['All', 'Invitations', 'My plans', 'Discover']
                            .map(
                              (label) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(label),
                                  selected: _filter == label,
                                  onSelected: (_) =>
                                      setState(() => _filter = label),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_loading) const LinearProgressIndicator(),
                    if (_loadError != null)
                      Card(
                        color: const Color(0xFFFFF1DD),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(_loadError!),
                        ),
                      ),
                    if (_showExamples)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE9EDE8),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.auto_awesome_outlined, size: 20),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Five example plans to explore the layout. Your own activities are saved separately.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _showExamples = false),
                              child: const Text('Hide examples'),
                            ),
                          ],
                        ),
                      )
                    else
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => setState(() => _showExamples = true),
                          child: const Text('Show examples'),
                        ),
                      ),
                    if (_filter == 'All' || _filter == 'Invitations')
                      _group(
                        'Waiting for you',
                        'A quick yes or no helps everyone plan.',
                        invitations,
                        empty: _filter == 'Invitations'
                            ? 'You’re all caught up. New invitations will appear here.'
                            : null,
                      ),
                    if (_filter == 'All' || _filter == 'My plans') ...[
                      _group(
                        'Your next plans',
                        'Your place is confirmed. Everything you need is one tap away.',
                        plans,
                      ),
                      _group(
                        'You’re hosting',
                        'Keep it private or open the remaining places.',
                        hosting,
                      ),
                    ],
                    if (_filter == 'All' || _filter == 'Discover')
                      _group(
                        'Worth joining',
                        'Public plans in your city. Explore before you decide.',
                        suggested,
                        empty: _filter == 'Discover'
                            ? 'No public plans to suggest yet. Why not start one?'
                            : null,
                      ),
                    if (_filter == 'All' || _filter == 'Invitations')
                      _group(
                        'Your replies',
                        'Changed your mind? Reopen an invitation to update your answer.',
                        replies,
                      ),
                    if (all.isEmpty && !_loading)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const Icon(Icons.event_available, size: 40),
                            const SizedBox(height: 12),
                            const Text('Your next plan starts with you.'),
                            TextButton(
                              onPressed: () => _selectTab(1),
                              child: const Text('Create your first activity'),
                            ),
                          ],
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

  Widget _summary(
    String count,
    String label,
    IconData icon,
    VoidCallback tap,
  ) => ActionChip(
    onPressed: tap,
    avatar: Icon(icon, size: 17),
    label: Text('$count $label'),
    backgroundColor: Colors.white,
    side: const BorderSide(color: Color(0xFFDCE5DF)),
  );
  Widget _group(
    String title,
    String subtitle,
    List<Activity> activities, {
    String? empty,
  }) {
    if (activities.isEmpty && empty == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFF64736D), fontSize: 13),
          ),
          const SizedBox(height: 14),
          if (activities.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(empty!),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth >= 700
                    ? (constraints.maxWidth - 16) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 16,
                  runSpacing: 14,
                  children: activities
                      .map((a) => SizedBox(width: width, child: _card(a)))
                      .toList(),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _card(Activity a) {
    final color = categoryColor(a.category);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFE0E7E1)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _open(a),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      categoryIcon(a.category),
                      color: color,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      activityCategories[a.category] ?? a.category,
                      style: TextStyle(
                        fontSize: 12,
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (a.demo)
                    const Text(
                      'EXAMPLE',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.black45,
                        letterSpacing: 1,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                a.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                a.when,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(
                    Icons.place_outlined,
                    size: 16,
                    color: Colors.black45,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      a.place,
                      style: const TextStyle(
                        color: Color(0xFF64736D),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _pill(
                    a.state == 'draft' ? 'Draft' : a.attendance,
                    a.full ? const Color(0xFFFFEDDC) : const Color(0xFFE6F1E9),
                  ),
                  _pill(
                    a.visibility == 'public' ? 'Public' : 'Invite only',
                    const Color(0xFFF1F3F0),
                  ),
                  _pill(
                    a.limit == null
                        ? '${a.count} going'
                        : '${a.count}/${a.limit} places',
                    const Color(0xFFF1F3F0),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'With ${a.host}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => _open(a),
                      child: Text(
                        a.data['is_host'] == true
                            ? 'Manage plan'
                            : a.invitation == 'pending'
                            ? 'View invitation'
                            : a.myStatus == 'confirmed'
                            ? 'View meetup'
                            : 'View activity',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
    ),
  );
}
