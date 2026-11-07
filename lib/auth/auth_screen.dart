import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';

enum AuthPage { welcome, login, register, verify, forgot, reset, profile }

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.service});
  final AuthService service;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  late final StreamSubscription<void> _subscription;
  late AuthPage _page;
  bool _busy = false, _hidden = true, _recovery = false;
  String? _error, _notice;
  Future<Map<String, dynamic>>? _profile;
  AuthService get auth => widget.service;

  @override
  void initState() {
    super.initState();
    _recovery = auth.recoveryEmail != null;
    _email.text = auth.recoveryEmail ?? '';
    _page = _recovery
        ? AuthPage.reset
        : auth.user?.emailConfirmedAt != null
        ? AuthPage.profile
        : AuthPage.welcome;
    if (_page == AuthPage.profile) _profile = auth.profile();
    _subscription = auth.changes.listen(
      (_) {
        if (!mounted || _busy) return;
        if (auth.user == null && _page == AuthPage.profile) {
          _go(AuthPage.welcome);
        } else if (auth.user?.emailConfirmedAt != null &&
            !_recovery &&
            _page != AuthPage.profile) {
          _go(AuthPage.profile);
        }
      },
      onError: (_) {
        if (mounted) {
          setState(
            () => _error = 'Your session could not be refreshed. Please try signing in again.',
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    for (final controller in [_email, _username, _password, _confirm, _code]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _go(AuthPage page) {
    setState(() {
      _page = page;
      _hidden = true;
      _error = null;
      _notice = null;
      _password.clear();
      _confirm.clear();
      _code.clear();
      if (page == AuthPage.profile) _profile = auth.profile();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FunctionException catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Account deletion failed. Check your password and try again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Something went wrong. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final email = _email.text.trim();
    await _run(() async {
      switch (_page) {
        case AuthPage.register:
          await auth.register(_username.text.trim(), email, _password.text);
          if (!mounted) return;
          _go(AuthPage.verify);
          break;
        case AuthPage.login:
          await auth.login(email, _password.text);
          if (!mounted) return;
          _go(
            auth.user?.emailConfirmedAt != null
                ? AuthPage.profile
                : AuthPage.verify,
          );
          break;
        case AuthPage.verify:
          await auth.verify(email, _code.text.trim());
          if (!mounted) return;
          _go(AuthPage.profile);
          break;
        case AuthPage.forgot:
          await auth.requestReset(email);
          if (!mounted) return;
          _recovery = true;
          _go(AuthPage.reset);
          break;
        case AuthPage.reset:
          if (auth.user == null) {
            await auth.verify(email, _code.text.trim(), recovery: true);
          }
          await auth.updatePassword(_password.text);
          _recovery = false;
          if (!mounted) return;
          _go(AuthPage.profile);
          break;
        default:
          break;
      }
    });
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? Function(String?)? validator,
    bool password = false,
    TextInputType? keyboard,
    Iterable<String>? hints,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: !_busy,
      keyboardType: keyboard,
      autofillHints: hints,
      autocorrect: false,
      enableSuggestions: !password,
      obscureText: password && _hidden,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: password
            ? IconButton(
                tooltip: _hidden ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => _hidden = !_hidden),
                icon: Icon(
                  _hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              )
            : null,
      ),
      onFieldSubmitted: (_) => _submit(),
    ),
  );

  Future<void> _delete() async {
    final password = TextEditingController();
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your account and profile will be permanently deleted. Enter your password to confirm.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    final value = password.text;
    // Dispose after the dialog's closing animation has released its text field.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 1), password.dispose),
    );
    if (approved != true || !mounted) return;
    if (value.isEmpty) {
      setState(() => _error = 'Enter your password to delete your account.');
      return;
    }
    await _run(() async {
      await auth.deleteAccount(value);
      if (mounted) {
        _go(AuthPage.welcome);
        _email.clear();
        _username.clear();
      }
    });
  }

  Widget _profileView() => FutureBuilder<Map<String, dynamic>>(
    future: _profile,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Column(
          children: [
            const Text('Unable to load your profile.'),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() => _profile = auth.profile()),
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await auth.logout();
                      if (mounted) _go(AuthPage.welcome);
                    }),
              child: const Text('Sign out'),
            ),
          ],
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final profile = snapshot.data!;
      final username = profile['username'] as String;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CircleAvatar(
            radius: 38,
            child: Text(
              username.substring(0, 1).toUpperCase(),
              style: const TextStyle(fontSize: 30),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            username,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.mail_outline),
            title: Text(auth.user?.email ?? ''),
            subtitle: const Text('Email verified'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today_outlined),
            title: const Text('Member since'),
            subtitle: Text((profile['created_at'] as String).split('T').first),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await auth.logout();
                    if (mounted) _go(AuthPage.welcome);
                  }),
            child: const Text('Sign out'),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: _busy ? null : _delete,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete account'),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final title = switch (_page) {
      AuthPage.welcome => 'Your city. Your people.',
      AuthPage.login => 'Welcome back',
      AuthPage.register => 'Create your account',
      AuthPage.verify => 'Check your email',
      AuthPage.forgot => 'Forgot your password?',
      AuthPage.reset => 'Reset your password',
      AuthPage.profile => 'Your profile',
    };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 440,
              child: AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(
                        Icons.explore_outlined,
                        size: 46,
                        color: Color(0xFF196C5D),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'CITY TOGETHER',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          letterSpacing: 3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 36),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      if (_page == AuthPage.welcome) ...[
                        const Text(
                          'Discover something to do. Meet people to do it with.',
                        ),
                        const SizedBox(height: 32),
                        FilledButton(
                          onPressed: () => _go(AuthPage.login),
                          child: const Text('Sign in'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () => _go(AuthPage.register),
                          child: const Text('Create account'),
                        ),
                      ] else if (_page == AuthPage.profile)
                        _profileView()
                      else ...[
                        if (_page == AuthPage.verify ||
                            _page == AuthPage.reset) ...[
                          Text(
                            _page == AuthPage.reset && auth.user != null
                                ? 'Your email is verified. Choose your new password.'
                                : 'Enter the code sent to ${_email.text.trim()}. Check your spam folder too.',
                          ),
                          const SizedBox(height: 24),
                        ] else
                          const SizedBox(height: 16),
                        if (_page == AuthPage.verify) ...[
                          const Text(
                            'If you already registered with this email, your original username is kept.',
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_page == AuthPage.register)
                          _field(
                            'Username',
                            _username,
                            validator: validateUsername,
                            hints: [AutofillHints.newUsername],
                          ),
                        if ([
                          AuthPage.register,
                          AuthPage.login,
                          AuthPage.forgot,
                          AuthPage.verify,
                        ].contains(_page))
                          _field(
                            'Email',
                            _email,
                            validator: validateEmail,
                            keyboard: TextInputType.emailAddress,
                            hints: [AutofillHints.email],
                          ),
                        if (_page == AuthPage.verify ||
                            (_page == AuthPage.reset && auth.user == null))
                          _field(
                            'Verification code',
                            _code,
                            keyboard: TextInputType.number,
                            hints: [AutofillHints.oneTimeCode],
                            validator: (value) =>
                                RegExp(r'^\d{6,10}$')
                                    .hasMatch(value?.trim() ?? '')
                                ? null
                                : 'Enter the code from your email.',
                          ),
                        if ([
                          AuthPage.login,
                          AuthPage.register,
                          AuthPage.reset,
                        ].contains(_page))
                          _field(
                            _page == AuthPage.reset
                                ? 'New password'
                                : 'Password',
                            _password,
                            password: true,
                            hints: [
                              _page == AuthPage.login
                                  ? AutofillHints.password
                                  : AutofillHints.newPassword,
                            ],
                            validator: _page == AuthPage.login
                                ? (value) => value == null || value.isEmpty
                                      ? 'Enter your password.'
                                      : null
                                : validatePassword,
                          ),
                        if (_page == AuthPage.register ||
                            _page == AuthPage.reset)
                          _field(
                            'Confirm password',
                            _confirm,
                            password: true,
                            validator: (value) => value == _password.text
                                ? null
                                : 'Passwords do not match.',
                          ),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: Text(switch (_page) {
                            AuthPage.login => 'Sign in',
                            AuthPage.register => 'Create account',
                            AuthPage.verify => 'Verify email',
                            AuthPage.forgot => 'Send reset code',
                            AuthPage.reset => 'Save new password',
                            _ => 'Continue',
                          }),
                        ),
                        if (_page == AuthPage.login) ...[
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _go(AuthPage.forgot),
                            child: const Text('Forgot password?'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _go(AuthPage.verify),
                            child: const Text('Have a verification code?'),
                          ),
                        ],
                        if (_page == AuthPage.verify || _page == AuthPage.reset)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run(() async {
                                    if (_page == AuthPage.reset) {
                                      await auth.requestReset(
                                        _email.text.trim(),
                                      );
                                    } else {
                                      await auth.resend(_email.text.trim());
                                    }
                                    if (mounted) {
                                      setState(
                                        () => _notice = 'If the address is eligible, a new code has been sent.',
                                      );
                                    }
                                  }),
                            child: const Text('Resend code'),
                          ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  if (_recovery) {
                                    await _run(() async {
                                      await auth.logout();
                                      _recovery = false;
                                      if (mounted) _go(AuthPage.login);
                                    });
                                  } else {
                                    _go(AuthPage.welcome);
                                  }
                                },
                          child: const Text('Back to welcome'),
                        ),
                      ],
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            _error!,
                            semanticsLabel: 'Error: $_error',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if (_notice != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(_notice!),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
