import 'package:flutter/material.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';
import '../../chats/presentation/chats_tab.dart';

class ContactsTab extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;

  const ContactsTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.me,
  });

  @override
  State<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<ContactsTab> {
  final _searchController = TextEditingController();
  bool _loading = false;
  List<AppUser> _results = const [];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String? _userChatQuery(AppUser user) {
    final handle = user.publicHandle;
    if (handle != null && handle.isNotEmpty) return handle;
    final phone = user.phone?.trim();
    if (phone != null && phone.isNotEmpty) return phone;
    return null;
  }

  String _subtitleForUser(AppUser user) {
    final parts = <String>[
      if (user.publicHandle != null) user.publicHandle!,
      if (user.phone != null && user.phone!.trim().isNotEmpty) user.phone!,
    ];
    if (parts.isEmpty) return 'No public username';
    return parts.join('  •  ');
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    final tokens = widget.getTokens();
    if (tokens == null || query.length < 2) return;

    setState(() => _loading = true);
    try {
      final users = await widget.api.searchUsers(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: query,
      );
      if (!mounted) return;
      setState(() {
        _results = users.where((user) => user.id != widget.me.id).toList();
      });
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openDialogAndCreate() async {
    final queryController = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Find user'),
          content: TextField(
            controller: queryController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Phone, @username or profile link',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, queryController.text.trim()),
              child: const Text('Open chat'),
            ),
          ],
        );
      },
    );

    if (query == null || query.isEmpty) return;
    final tokens = widget.getTokens();
    if (tokens == null) return;
    try {
      final chat = await widget.api.openPrivateChat(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: query,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            api: widget.api,
            getTokens: widget.getTokens,
            chat: chat,
            me: widget.me,
          ),
        ),
      );
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _openChatForUser(AppUser user) async {
    final query = _userChatQuery(user);
    if (query == null) {
      _showSnack('This user has neither phone nor public username.');
      return;
    }

    final tokens = widget.getTokens();
    if (tokens == null) return;
    try {
      final chat = await widget.api.openPrivateChat(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: query,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            api: widget.api,
            getTokens: widget.getTokens,
            chat: chat,
            me: widget.me,
          ),
        ),
      );
    } catch (error) {
      _showSnack(error.toString());
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            onPressed: _openDialogAndCreate,
            icon: const Icon(Icons.person_add_alt_1_rounded),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(context.sp(12)),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search by phone, @username, link or name',
              ),
              onSubmitted: (_) => _search(),
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: context.sp(10)),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                    _searchController.text.trim().length >= 2 && !_loading
                    ? _search
                    : null,
                child: _loading
                    ? SizedBox(
                        width: context.sp(16),
                        height: context.sp(16),
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Search'),
              ),
            ),
            SizedBox(height: context.sp(8)),
            Expanded(
              child: _results.isEmpty
                  ? const Center(child: Text('No results'))
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, index) =>
                          SizedBox(height: context.sp(6)),
                      itemBuilder: (context, index) {
                        final user = _results[index];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text(
                                user.displayName.characters.first.toUpperCase(),
                              ),
                            ),
                            title: Text(user.displayName),
                            subtitle: Text(_subtitleForUser(user)),
                            onTap: () => _openChatForUser(user),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
