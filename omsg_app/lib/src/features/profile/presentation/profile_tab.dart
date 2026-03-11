import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';
import 'public_profile_screen.dart';

class ProfileTab extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;
  final Future<void> Function(AppUser user) onUserUpdated;

  const ProfileTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.me,
    required this.onUserUpdated,
  });

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  static final RegExp _usernamePattern = RegExp(r'^[a-z][a-z0-9_]{4,31}$');

  late TextEditingController _usernameController;
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _bioController;

  Timer? _usernameDebounce;
  bool _checkingUsername = false;
  bool? _usernameAvailable;
  String? _checkedUsername;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: widget.me.username ?? '');
    _firstNameController = TextEditingController(text: widget.me.firstName);
    _lastNameController = TextEditingController(text: widget.me.lastName);
    _bioController = TextEditingController(text: widget.me.bio);
    _syncUsernameState(immediate: true);
  }

  @override
  void didUpdateWidget(covariant ProfileTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.me.id != widget.me.id ||
        oldWidget.me.username != widget.me.username ||
        oldWidget.me.firstName != widget.me.firstName ||
        oldWidget.me.lastName != widget.me.lastName ||
        oldWidget.me.bio != widget.me.bio) {
      _usernameController.text = widget.me.username ?? '';
      _firstNameController.text = widget.me.firstName;
      _lastNameController.text = widget.me.lastName;
      _bioController.text = widget.me.bio;
      _syncUsernameState(immediate: true);
    }
  }

  @override
  void dispose() {
    _usernameDebounce?.cancel();
    _usernameController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  String get _currentUsername =>
      (widget.me.username ?? '').trim().toLowerCase();

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

  bool get _hasChanges =>
      _normalizedUsername != _currentUsername ||
      _firstNameController.text.trim() != widget.me.firstName ||
      _lastNameController.text.trim() != widget.me.lastName ||
      _bioController.text.trim() != widget.me.bio;

  bool get _canSave =>
      !_saving &&
      _hasChanges &&
      _firstNameController.text.trim().isNotEmpty &&
      _usernameFormatError == null &&
      _usernameResolved;

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
      return 'Optional. Leave blank to remove public @username.';
    }
    if (_normalizedUsername == _currentUsername) {
      return 'This is your current public username.';
    }
    if (_checkingUsername) return 'Checking availability...';
    if (_checkedUsername == _normalizedUsername && _usernameAvailable == true) {
      return 'Username is available.';
    }
    return 'People can find you by this @username.';
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

  Future<void> _saveProfile() async {
    if (!_canSave) return;
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
        bio: _bioController.text.trim(),
      );
      await widget.onUserUpdated(updated);
      if (!mounted) return;
      _showSnack('Profile updated');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyPublicLink() async {
    final handle = widget.me.username;
    if (handle == null || handle.trim().isEmpty) {
      _showSnack('Set a public username first');
      return;
    }
    await Clipboard.setData(
      ClipboardData(text: widget.api.publicProfileUrl(handle)),
    );
    if (!mounted) return;
    _showSnack('Profile link copied');
  }

  Future<void> _previewPublicProfile() async {
    final handle = widget.me.username;
    if (handle == null || handle.trim().isEmpty) {
      _showSnack('Set a public username first');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PublicProfileScreen(
          api: widget.api,
          getTokens: widget.getTokens,
          username: handle,
          viewer: widget.me,
        ),
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: EdgeInsets.all(context.sp(12)),
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(context.sp(14)),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: context.sp(34),
                    child: Text(
                      widget.me.displayName.characters.first.toUpperCase(),
                      style: TextStyle(
                        fontSize: context.sp(24),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(height: context.sp(10)),
                  Text(
                    widget.me.displayName,
                    style: TextStyle(
                      fontSize: context.sp(22),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: context.sp(4)),
                  Text(
                    widget.me.publicHandle ?? 'No public username',
                    style: TextStyle(
                      fontSize: context.sp(14),
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (widget.me.phone != null)
                    Padding(
                      padding: EdgeInsets.only(top: context.sp(4)),
                      child: Text(
                        widget.me.phone!,
                        style: TextStyle(
                          fontSize: context.sp(14),
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (widget.me.publicHandle != null) ...[
                    SizedBox(height: context.sp(14)),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _copyPublicLink,
                            icon: const Icon(Icons.link_rounded),
                            label: const Text('Copy link'),
                          ),
                        ),
                        SizedBox(width: context.sp(10)),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: _previewPublicProfile,
                            icon: const Icon(Icons.public_rounded),
                            label: const Text('Preview'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _usernameController,
            autocorrect: false,
            textCapitalization: TextCapitalization.none,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_@]')),
            ],
            decoration: InputDecoration(
              labelText: 'Public username',
              prefixText: '@',
              helperText: _usernameHelperText,
              errorText: _usernameErrorText,
              suffixIcon: _usernameSuffix,
            ),
            onChanged: _handleUsernameChanged,
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _firstNameController,
            decoration: const InputDecoration(labelText: 'First name'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _lastNameController,
            decoration: const InputDecoration(labelText: 'Last name'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(10)),
          TextField(
            controller: _bioController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Bio'),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.sp(14)),
          FilledButton(
            onPressed: _canSave ? _saveProfile : null,
            child: _saving
                ? SizedBox(
                    width: context.sp(16),
                    height: context.sp(16),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
