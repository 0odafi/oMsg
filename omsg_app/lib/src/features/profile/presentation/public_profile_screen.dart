import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';
import '../../chats/presentation/chats_tab.dart';

class PublicProfileScreen extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final String username;
  final AppUser? viewer;

  const PublicProfileScreen({
    super.key,
    required this.api,
    required this.getTokens,
    required this.username,
    required this.viewer,
  });

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  AppUser? _profile;
  bool _loading = true;
  bool _openingChat = false;

  String get _normalizedUsername => normalizePublicUsername(widget.username);

  bool get _isOwnProfile =>
      widget.viewer?.username?.trim().toLowerCase() == _normalizedUsername;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _loading = true);
    try {
      final profile = await widget.api.publicProfile(_normalizedUsername);
      if (!mounted) return;
      setState(() => _profile = profile);
    } catch (error) {
      if (!mounted) return;
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(
      ClipboardData(text: widget.api.publicProfileUrl(_normalizedUsername)),
    );
    if (!mounted) return;
    _showSnack('Profile link copied');
  }

  Future<void> _openChat() async {
    if (_openingChat || _profile == null || _isOwnProfile) return;
    final tokens = widget.getTokens();
    if (tokens == null) {
      _showSnack('Sign in to message this user');
      return;
    }

    setState(() => _openingChat = true);
    try {
      final chat = await widget.api.openPrivateChat(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: '@$_normalizedUsername',
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            api: widget.api,
            getTokens: widget.getTokens,
            chat: chat,
            me: widget.viewer!,
          ),
        ),
      );
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _openingChat = false);
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
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(title: Text('@$_normalizedUsername')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : profile == null
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(context.sp(24)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Public profile not found'),
                    SizedBox(height: context.sp(12)),
                    OutlinedButton(
                      onPressed: _loadProfile,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: EdgeInsets.all(context.sp(12)),
              children: [
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(context.sp(18)),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: context.sp(42),
                          child: Text(
                            profile.displayName.characters.first.toUpperCase(),
                            style: TextStyle(
                              fontSize: context.sp(28),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        SizedBox(height: context.sp(14)),
                        Text(
                          profile.displayName,
                          style: TextStyle(
                            fontSize: context.sp(24),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: context.sp(6)),
                        Text(
                          profile.publicHandle ?? '@$_normalizedUsername',
                          style: TextStyle(
                            fontSize: context.sp(15),
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (profile.bio.trim().isNotEmpty) ...[
                          SizedBox(height: context.sp(16)),
                          Text(
                            profile.bio,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: context.sp(15),
                              height: 1.5,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                SizedBox(height: context.sp(10)),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copyLink,
                        icon: const Icon(Icons.link_rounded),
                        label: const Text('Copy link'),
                      ),
                    ),
                    SizedBox(width: context.sp(10)),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            (_isOwnProfile ||
                                widget.viewer == null ||
                                _openingChat)
                            ? null
                            : _openChat,
                        icon: _openingChat
                            ? SizedBox(
                                width: context.sp(16),
                                height: context.sp(16),
                                child: const CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.chat_bubble_rounded),
                        label: Text(_isOwnProfile ? 'This is you' : 'Message'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
