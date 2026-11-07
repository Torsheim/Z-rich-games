import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'friend_service.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

class FriendsSection extends StatefulWidget {
  const FriendsSection({super.key, required this.service});
  final FriendService service;
  @override
  State<FriendsSection> createState() => _FriendsSectionState();
}

class _FriendsSectionState extends State<FriendsSection>
    with WidgetsBindingObserver {
  late Future<List<Map<String, dynamic>>> _friends;
  bool _busy = false;
  String? _error;
  RealtimeChannel? _channel;
  FriendService get service => widget.service;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _friends = service.list();
    _channel = service.watchFriends(() {
      if (mounted) _refresh();
    });
    service.addListener(_incoming);
    WidgetsBinding.instance.addPostFrameCallback((_) => _incoming());
  }

  @override
  void dispose() {
    service.removeListener(_incoming);
    if (_channel != null) unawaited(service.client.removeChannel(_channel!));
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) _refresh();
  }

  void _refresh() {
    setState(() => _friends = service.list());
  }

  void _incoming() {
    final token = service.pendingToken;
    if (mounted && !_busy && token != null) {
      unawaited(_confirm(token, pending: true));
    }
  }

  Future<void> _confirm(String token, {bool pending = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final person = await service.preview(token);
      if (!mounted) return;
      if (person == null) {
        setState(
          () => _error = 'This invitation has expired or is no longer valid. Ask for a new link or QR code.',
        );
        if (pending) await service.clearPending(token);
        return;
      }
      final self = person['is_self'] == true;
      final exists = person['already_friends'] == true;
      final name = person['username'] as String;
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(
            self
                ? 'This is your invitation'
                : exists
                ? 'Already friends'
                : 'Add $name as a friend?',
          ),
          content: Text(
            self
                ? 'Share this invitation with someone else.'
                : exists
                ? 'You and $name are already friends.'
                : 'You will appear in each other’s friends list. Only confirm if you recognize $name.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(self || exists ? 'Close' : 'Cancel'),
            ),
            if (!self && !exists)
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Add friend'),
              ),
          ],
        ),
      );
      if (yes == true && mounted) {
        await service.accept(token);
        if (!mounted) return;
        _refresh();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('You and $name are now friends.')),
        );
      }
      if (pending) await service.clearPending(token);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Unable to open or accept this invitation. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (service.pendingToken != null && service.pendingToken != token) {
          _incoming();
        }
      }
    }
  }

  Future<void> _removeFriend(Map<String, dynamic> friend) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = friend['username'] as String;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Remove $name as a friend?'),
          scrollable: true,
          content: const Text(
            'You will be removed from each other’s friends list.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove friend'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await service.remove(friend['user_id'] as String);
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$name removed from friends.')));
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Unable to remove friend. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final invite = await service.invitation();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _InviteDialog(service: service, initial: invite),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Unable to load your invitation. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const FriendScanner()));
    if (raw == null || !mounted) return;
    await _openLink(raw);
  }

  Future<void> _openLink(String value) async {
    final uri = Uri.tryParse(value.trim());
    final token = uri == null ? null : invitationToken(uri, service.publicBase);
    if (token == null) {
      setState(() => _error = 'This is not a City Together invitation.');
      return;
    }
    await _confirm(token);
  }

  Future<void> _pasteLink() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open an invitation'),
        scrollable: true,
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Invitation link'),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    unawaited(
      Future<void>.delayed(const Duration(seconds: 1), controller.dispose),
    );
    if (value != null && mounted) await _openLink(value);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 36),
      Row(
        children: [
          Text('Friends', style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh friends',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      const Text(
        'Connect in person with a QR code, or share your invitation link.',
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _busy ? null : _showCode,
        icon: const Icon(Icons.qr_code),
        label: const Text('My QR code & link'),
      ),
      OutlinedButton.icon(
        onPressed: _busy ? null : _scan,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan a QR code'),
      ),
      TextButton(
        onPressed: _busy ? null : _pasteLink,
        child: const Text('Open invitation link'),
      ),
      if (_busy) const Text('Please wait…'),
      if (_error != null) ...[
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        if (service.pendingToken != null)
          TextButton(
            onPressed: _busy ? null : _incoming,
            child: const Text('Retry invitation'),
          ),
      ],
      FutureBuilder<List<Map<String, dynamic>>>(
        future: _friends,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Unable to load friends. Tap refresh to try again.'),
            );
          }
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data!.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('No friends yet. Your next connection starts here.'),
            );
          }
          return Column(
            children: snapshot.data!
                .map(
                  (friend) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      child: Icon(Icons.person_outline),
                    ),
                    title: Text(friend['username'] as String),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _removeFriend(friend),
                      child: const Text('Remove'),
                    ),
                  ),
                )
                .toList(),
          );
        },
      ),
    ],
  );
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.service, required this.initial});
  final FriendService service;
  final Map<String, dynamic> initial;
  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  late Map<String, dynamic> _invite = widget.initial;
  bool _busy = false;
  String? _message;
  @override
  Widget build(BuildContext context) {
    final link = widget.service.linkFor(_invite['token'] as String);
    return AlertDialog(
      title: const Text('Your friend invitation'),
      scrollable: true,
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Showing or sharing this invitation lets someone add you after they confirm.',
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 240,
              height: 240,
              child: QrImageView(
                data: link,
                size: 240,
                backgroundColor: Colors.white,
                semanticsLabel: 'Your friend invitation QR code',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SelectableText(link)),
                IconButton(
                  tooltip: 'Copy link',
                  onPressed: _busy
                      ? null
                      : () async {
                          try {
                            await Clipboard.setData(ClipboardData(text: link));
                            if (mounted) {
                              setState(
                                () => _message =
                                    'Link copied. You can send it to a friend.',
                              );
                            }
                          } catch (_) {
                            if (mounted) {
                              setState(
                                () => _message = 'Could not copy. Select and copy the link above.',
                              );
                            }
                          }
                        },
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Valid until ${(_invite['expires_at'] as String).split('T').first}. Replacing it disables the old QR code and link.',
            ),
            if (_message != null) Text(_message!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    final next = await widget.service.invitation(rotate: true);
                    if (mounted) {
                      setState(() {
                        _invite = next;
                        _message = 'Invitation replaced.';
                      });
                    }
                  } catch (_) {
                    if (mounted) {
                      setState(
                        () => _message =
                            'Unable to replace invitation. Try again.',
                      );
                    }
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: const Text('Replace invitation'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class FriendScanner extends StatefulWidget {
  const FriendScanner({super.key});
  @override
  State<FriendScanner> createState() => _FriendScannerState();
}

class _FriendScannerState extends State<FriendScanner> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan a friend’s QR code')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text('Point your camera at their City Together QR code.'),
        ),
        Expanded(
          child: MobileScanner(
            errorBuilder: (context, error) => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Camera unavailable. Allow camera access in your device or browser settings, or open the invitation link from your profile.',
                ),
              ),
            ),
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                if (!_done && barcode.rawValue != null) {
                  _done = true;
                  Navigator.pop(context, barcode.rawValue);
                  break;
                }
              }
            },
          ),
        ),
      ],
    ),
  );
}
