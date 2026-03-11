import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';

class ProfileSetupScreen extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser user;
  final Future<void> Function(AppUser user) onCompleted;
  final Future<void> Function() onLogout;

  const ProfileSetupScreen({
    super.key,
    required this.api,
    required this.getTokens,
    required this.user,
    required this.onCompleted,
    required this.onLogout,
  });

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  static final RegExp _usernamePattern = RegExp(r'^[a-z][a-z0-9_]{4,31}$');

  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _usernameController;

  Timer? _usernameDebounce;
  bool _checkingUsername = false;
  bool? _usernameAvailable;
  String? _checkedUsername;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.user.firstName);
    _lastNameController = TextEditingController(text: widget.user.lastName);
    _usernameController = TextEditingController(
      text: widget.user.usernameLooksGenerated
          ? ''
          : (widget.user.username ?? ''),
    );
    _syncUsernameState(immediate: true);
  }

  @override
  void dispose() {
    _usernameDebounce?.cancel();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  String get _currentUsername =>
      (widget.user.username ?? '').trim().toLowerCase();

  String get _normalizedUsername => _usernameController.text
      .trim()
      .replaceFirst(RegExp(r'^@+'), '')
      .toLowerCase();

  bool get _usernameProvided => _normalizedUsername.isNotEmpty;

  String? get _usernameFormatError {
    if (!_usernameProvided) return null;
    if (_usernamePattern.hasMatch(_normalizedUsername)) return null;
    return '5-32 chars, start with a letter, use letters, numbers or underscore.';
  }

  bool get _usernameResolved {
    if (!_usernameProvided) return true;
    if (_normalizedUsername == _currentUsername) return true;
    return !_checkingUsername &&
        _checkedUsername == _normalizedUsername &&
        _usernameAvailable == true;
  }

  bool get _canContinue =>
      _firstNameController.text.trim().isNotEmpty &&
      _usernameFormatError == null &&
      _usernameResolved &&
      !_saving;

  String? get _usernameErrorText {
    final formatError = _usernameFormatError;
    if (formatError != null) return formatError;
    if (_usernameProvided &&
        !_checkingUsername &&
        _checkedUsername == _normalizedUsername &&
        _usernameAvailable == false) {
      return 'This username is already taken.';
    }
    return null;
  }

  String get _usernameHelperText {
    if (!_usernameProvided) {
      return 'Optional. Add a public @username now or skip and set it later.';
    }
    if (_normalizedUsername == _currentUsername) {
      return 'This is already your public username.';
    }
    if (_checkingUsername) return 'Checking availability...';
    if (_checkedUsername == _normalizedUsername && _usernameAvailable == true) {
      return 'Username is available.';
    }
    return 'People will be able to find you by this @username.';
  }

  Widget? get _usernameSuffix {
    if (_checkingUsername) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: context.sp(16),
          height: context.sp(16),
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_usernameProvided &&
        _checkedUsername == _normalizedUsername &&
        _usernameAvailable == true &&
        _usernameFormatError == null) {
      return Icon(
        Icons.check_circle_rounded,
        color: Theme.of(context).colorScheme.primary,
      );
    }
    return null;
  }

  void _handleUsernameChanged(String value) {
    final sanitized = value.replaceFirst(RegExp(r'^@+'), '');
    if (sanitized != value) {
      _usernameController.value = TextEditingValue(
        text: sanitized,
        selection: TextSelection.collapsed(offset: sanitized.length),
      );
    }
    _syncUsernameState();
  }

  void _syncUsernameState({bool immediate = false}) {
    _usernameDebounce?.cancel();
    final normalized = _normalizedUsername;

    if (normalized.isEmpty) {
      setState(() {
        _checkingUsername = false;
        _checkedUsername = null;
        _usernameAvailable = null;
      });
      return;
    }

    if (_usernameFormatError != null) {
      setState(() {
        _checkingUsername = false;
        _checkedUsername = normalized;
        _usernameAvailable = null;
      });
      return;
    }

    if (normalized == _currentUsername) {
      setState(() {
        _checkingUsername = false;
        _checkedUsername = normalized;
        _usernameAvailable = true;
      });
      return;
    }

    void runCheck() {
      if (!mounted) return;
      setState(() {
        _checkingUsername = true;
        _checkedUsername = normalized;
        _usernameAvailable = null;
      });
      unawaited(_checkUsername(normalized));
    }

    if (immediate) {
      runCheck();
    } else {
      _usernameDebounce = Timer(const Duration(milliseconds: 350), runCheck);
      setState(() {});
    }
  }

  Future<void> _checkUsername(String normalized) async {
    final tokens = widget.getTokens();
    if (tokens == null) return;

    try {
      final result = await widget.api.checkUsername(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        username: normalized,
      );
      if (!mounted || _normalizedUsername != normalized) return;
      setState(() {
        _checkingUsername = false;
        _checkedUsername = normalized;
        _usernameAvailable = result.available;
      });
    } catch (error) {
      if (!mounted || _normalizedUsername != normalized) return;
      setState(() {
        _checkingUsername = false;
        _checkedUsername = normalized;
        _usernameAvailable = null;
      });
      _showSnack(error.toString());
    }
  }

  Future<void> _save() async {
    if (!_canContinue) return;
    final tokens = widget.getTokens();
    if (tokens == null) return;

    setState(() => _saving = true);
    try {
      final updated = await widget.api.updateMe(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        username: _usernameProvided ? _normalizedUsername : '',
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
      );
      await widget.onCompleted(updated);
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final identitySeed = widget.user.phone ?? widget.user.displayName;
    final initial = identitySeed
        .replaceAll('+', '')
        .characters
        .first
        .toUpperCase();

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              theme.colorScheme.surface,
              theme.colorScheme.surfaceContainerLow,
              theme.colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: context.sp(560)),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(context.sp(22)),
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(context.sp(22)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: context.sp(30),
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Text(
                            initial,
                            style: TextStyle(
                              fontSize: context.sp(24),
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        SizedBox(height: context.sp(16)),
                        Text(
                          'Finish your profile',
                          style: TextStyle(
                            fontSize: context.sp(28),
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                          ),
                        ),
                        SizedBox(height: context.sp(8)),
                        Text(
                          'Your phone is the account key. First name is required. Public @username is optional and can be added later, like in Telegram.',
                          style: TextStyle(
                            fontSize: context.sp(15),
                            height: 1.45,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        SizedBox(height: context.sp(16)),
                        if (widget.user.phone != null)
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.sp(14),
                              vertical: context.sp(12),
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                context.sp(16),
                              ),
                              color: theme.colorScheme.surfaceContainerHighest,
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.smartphone_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                                SizedBox(width: context.sp(10)),
                                Expanded(
                                  child: Text(
                                    widget.user.phone!,
                                    style: TextStyle(
                                      fontSize: context.sp(14),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        SizedBox(height: context.sp(18)),
                        TextField(
                          controller: _firstNameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'First name',
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        SizedBox(height: context.sp(12)),
                        TextField(
                          controller: _lastNameController,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Last name (optional)',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        SizedBox(height: context.sp(12)),
                        TextField(
                          controller: _usernameController,
                          autocorrect: false,
                          textCapitalization: TextCapitalization.none,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[A-Za-z0-9_@]'),
                            ),
                          ],
                          decoration: InputDecoration(
                            labelText: 'Public username (optional)',
                            prefixText: '@',
                            prefixIcon: const Icon(
                              Icons.alternate_email_rounded,
                            ),
                            helperText: _usernameHelperText,
                            errorText: _usernameErrorText,
                            suffixIcon: _usernameSuffix,
                          ),
                          onChanged: _handleUsernameChanged,
                        ),
                        SizedBox(height: context.sp(18)),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _saving ? null : widget.onLogout,
                                child: const Text('Log out'),
                              ),
                            ),
                            SizedBox(width: context.sp(10)),
                            Expanded(
                              child: FilledButton(
                                onPressed: _canContinue ? _save : null,
                                child: _saving
                                    ? SizedBox(
                                        width: context.sp(18),
                                        height: context.sp(18),
                                        child: const CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('Continue'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
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
