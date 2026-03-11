import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api.dart';
import '../../../core/cache/attachment_cache.dart';
import '../../../core/realtime/realtime_cursor_store.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../core/ui/app_appearance.dart';
import '../../../models.dart';
import '../../../realtime.dart';
import '../../audio/application/chat_audio_playback_controller.dart';
import '../../settings/application/app_preferences.dart';
import '../application/chat_view_models.dart';
import '../data/chat_composer_queue_local_cache.dart';
import '../data/chat_drafts_local_cache.dart';
import 'media_viewers.dart';

const List<String> _kQuickReactionEmoji = <String>[
  '👍',
  '❤️',
  '🔥',
  '😂',
  '😮',
  '😢',
];

const List<String> _kFolderPresets = <String>[
  'personal',
  'work',
  'friends',
  'family',
  'bots',
  'channels',
];

bool _isMediaAlbumCandidate(List<MessageAttachmentItem> attachments) {
  if (attachments.length < 2) return false;
  return attachments.every((item) => item.isImage || item.isVideo);
}

String _folderLabel(String folder) {
  final cleaned = folder.trim();
  if (cleaned.isEmpty) return 'No folder';
  return cleaned[0].toUpperCase() + cleaned.substring(1);
}

String _formatMessageTimestamp(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

enum _PendingComposerAction {
  apply,
  sendNow,
  sendSilently,
  scheduleAt,
  sendWhenOnline,
}

class ChatsTab extends ConsumerStatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;

  const ChatsTab({
    super.key,
    required this.api,
    required this.getTokens,
    required this.me,
  });

  @override
  ConsumerState<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends ConsumerState<ChatsTab> {
  final _searchController = TextEditingController();
  final RealtimeCursorStore _cursorStore = RealtimeCursorStore();
  late ChatListVmArgs _args;
  RealtimeMeSocket? _realtime;
  Timer? _refreshDebounce;
  bool _socketConnected = false;
  int _realtimeCursor = 0;

  @override
  void initState() {
    super.initState();
    _args = ChatListVmArgs(
      api: widget.api,
      getTokens: widget.getTokens,
      me: widget.me,
    );
    unawaited(ref.read(chatListViewModelProvider(_args)).prime());
    unawaited(_bootstrapRealtime());
  }

  @override
  void didUpdateWidget(covariant ChatsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api.baseUrl != widget.api.baseUrl ||
        oldWidget.me.id != widget.me.id) {
      _args = ChatListVmArgs(
        api: widget.api,
        getTokens: widget.getTokens,
        me: widget.me,
      );
      unawaited(ref.read(chatListViewModelProvider(_args)).prime());
      unawaited(_bootstrapRealtime());
    }
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _realtime?.stop();
    _searchController.dispose();
    super.dispose();
  }

  String _buildRealtimeUrl() {
    final tokens = widget.getTokens();
    if (tokens == null) return '';
    return '${webSocketBase(widget.api.baseUrl)}/api/realtime/me/ws?token=${Uri.encodeComponent(tokens.accessToken)}';
  }

  Future<void> _bootstrapRealtime() async {
    final cursor = await _cursorStore.loadCursor(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
    );
    if (!mounted) return;
    _realtimeCursor = cursor;
    _startRealtime();
  }

  void _startRealtime() {
    _realtime?.stop();
    _realtime = RealtimeMeSocket(
      urlBuilder: _buildRealtimeUrl,
      cursorGetter: () => _realtimeCursor,
      onEvent: _handleRealtimeEvent,
      onCursor: _rememberRealtimeCursor,
      onState: (state) {
        if (!mounted) return;
        final connected = state == RealtimeState.connected;
        if (_socketConnected != connected) {
          setState(() => _socketConnected = connected);
        }
        if (connected) {
          _scheduleBackgroundRefresh();
        }
      },
    )..start();
  }

  void _rememberRealtimeCursor(int cursor) {
    if (cursor <= _realtimeCursor) return;
    _realtimeCursor = cursor;
    unawaited(
      _cursorStore.saveCursor(
        baseUrl: widget.api.baseUrl,
        userId: widget.me.id,
        cursor: cursor,
      ),
    );
  }

  void _handleRealtimeEvent(Map<String, dynamic> event) {
    final type = (event['type'] ?? '').toString();
    if (type.isEmpty) return;
    switch (type) {
      case 'ready':
      case 'message':
      case 'message_status':
      case 'message_updated':
      case 'message_deleted':
      case 'chat_state':
        _scheduleBackgroundRefresh();
        break;
      default:
        break;
    }
  }

  void _scheduleBackgroundRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      unawaited(_loadChats(silent: true));
    });
  }

  Future<void> _loadChats({bool silent = false}) async {
    final error = await ref
        .read(chatListViewModelProvider(_args))
        .loadChats(silent: silent);
    if (error != null && !silent) {
      _showSnack(error);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _searchInMessages() async {
    final error = await ref
        .read(chatListViewModelProvider(_args))
        .searchInMessages(_searchController.text);
    if (error != null) {
      _showSnack(error);
    }
  }

  Future<void> _showChatActions(ChatItem chat) async {
    final tokens = widget.getTokens();
    if (tokens == null) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  chat.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: Text(chat.isPinned ? 'Unpin chat' : 'Pin chat'),
                onTap: () async {
                  Navigator.of(context).pop();
                  try {
                    await widget.api.updateChatState(
                      accessToken: tokens.accessToken,
                      refreshToken: tokens.refreshToken,
                      chatId: chat.id,
                      isPinned: !chat.isPinned,
                    );
                    await _loadChats();
                  } catch (error) {
                    _showSnack(error.toString());
                  }
                },
              ),
              ListTile(
                leading: Icon(
                  chat.isArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                title: Text(
                  chat.isArchived ? 'Unarchive chat' : 'Archive chat',
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  try {
                    await widget.api.updateChatState(
                      accessToken: tokens.accessToken,
                      refreshToken: tokens.refreshToken,
                      chatId: chat.id,
                      isArchived: !chat.isArchived,
                    );
                    await _loadChats();
                  } catch (error) {
                    _showSnack(error.toString());
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: Text(chat.folder == null ? 'Move to folder' : 'Change folder'),
                subtitle: chat.folder == null ? null : Text(_folderLabel(chat.folder!)),
                onTap: () async {
                  Navigator.of(context).pop();
                  final folder = await _pickFolder(chat.folder, ref.read(chatListViewModelProvider(_args)).availableFolders());
                  if (folder == null) return;
                  try {
                    await widget.api.updateChatState(
                      accessToken: tokens.accessToken,
                      refreshToken: tokens.refreshToken,
                      chatId: chat.id,
                      folder: folder,
                    );
                    await _loadChats();
                  } catch (error) {
                    _showSnack(error.toString());
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _applyQuickChatAction(
    ChatItem chat, {
    bool? isPinned,
    bool? isArchived,
  }) async {
    final tokens = widget.getTokens();
    if (tokens == null) return;
    try {
      await widget.api.updateChatState(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: chat.id,
        isPinned: isPinned,
        isArchived: isArchived,
      );
      await _loadChats(silent: true);
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _createPrivateChat() async {
    final controller = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Phone, @username or link',
              hintText: '+7900..., @username or https://.../u/name',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Open'),
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
      await _loadChats();
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _openSavedMessages() async {
    final tokens = widget.getTokens();
    if (tokens == null) return;
    try {
      final chat = await widget.api.openSavedMessagesChat(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
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
      await _loadChats();
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<String?> _promptCustomFolderName({String? initialValue}) async {
    final controller = TextEditingController(text: initialValue ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Custom folder'),
        content: TextField(
          controller: controller,
          maxLength: 32,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Folder name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final cleaned = result?.trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    return cleaned.toLowerCase();
  }

  Future<String?> _pickFolder(String? currentFolder, Iterable<String> suggestions) async {
    final current = currentFolder?.trim().toLowerCase();
    final folders = <String>{
      ..._kFolderPresets,
      ...suggestions.map((folder) => folder.trim().toLowerCase()).where((folder) => folder.isNotEmpty),
      if (current != null && current.isNotEmpty) current,
    }.toList()..sort();
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.clear_all_rounded),
                title: const Text('No folder'),
                trailing: current == null ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(context).pop(''),
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('Create custom folder'),
                onTap: () async {
                  final created = await _promptCustomFolderName(initialValue: currentFolder);
                  if (!context.mounted) return;
                  Navigator.of(context).pop(created);
                },
              ),
              ...folders.map((folder) => ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: Text(_folderLabel(folder)),
                trailing: current == folder ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(context).pop(folder),
              )),
            ],
          ),
        );
      },
    );
  }


  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(chatListViewModelProvider(_args));
    final appearance = ref.watch(appPreferencesProvider).appearance;
    final items = vm.filteredChats(_searchController.text);
    final showMessageHits = vm.messageHits.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          Icon(
            _socketConnected
                ? Icons.cloud_done_rounded
                : Icons.cloud_off_rounded,
            color: _socketConnected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
          IconButton(
            tooltip: 'Saved Messages',
            onPressed: _openSavedMessages,
            icon: const Icon(Icons.bookmark_rounded),
          ),
          IconButton(
            onPressed: _loadChats,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            onPressed: _createPrivateChat,
            icon: const Icon(Icons.add_comment_outlined),
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
                hintText: 'Search chats, @usernames, phone',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (_) {
                if (_searchController.text.trim().isEmpty &&
                    vm.messageHits.isNotEmpty) {
                  ref.read(chatListViewModelProvider(_args)).clearMessageHits();
                } else {
                  setState(() {});
                }
              },
            ),
            SizedBox(height: context.sp(10)),
            SizedBox(
              height: context.sp(42),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  FilterChip(
                    label: const Text('All'),
                    selected: vm.activeFilter == 'all',
                    onSelected: (_) {
                      if (vm.activeFilter == 'all') return;
                      ref
                          .read(chatListViewModelProvider(_args))
                          .setFilter('all');
                      unawaited(_loadChats(silent: true));
                    },
                  ),
                  SizedBox(width: context.sp(8)),
                  FilterChip(
                    label: const Text('Pinned'),
                    selected: vm.activeFilter == 'pinned',
                    onSelected: (_) {
                      if (vm.activeFilter == 'pinned') return;
                      ref
                          .read(chatListViewModelProvider(_args))
                          .setFilter('pinned');
                      unawaited(_loadChats(silent: true));
                    },
                  ),
                  SizedBox(width: context.sp(8)),
                  FilterChip(
                    label: const Text('Archived'),
                    selected: vm.activeFilter == 'archived',
                    onSelected: (_) {
                      if (vm.activeFilter == 'archived') return;
                      ref
                          .read(chatListViewModelProvider(_args))
                          .setFilter('archived');
                      unawaited(_loadChats(silent: true));
                    },
                  ),
                  SizedBox(width: context.sp(8)),
                  FilterChip(
                    label: const Text('Unread'),
                    selected: vm.activeFilter == 'unread',
                    onSelected: (_) {
                      if (vm.activeFilter == 'unread') return;
                      ref
                          .read(chatListViewModelProvider(_args))
                          .setFilter('unread');
                      unawaited(_loadChats(silent: true));
                    },
                  ),
                  SizedBox(width: context.sp(8)),
                  IconButton(
                    tooltip: 'Search in messages',
                    onPressed: vm.searchingMessages ? null : _searchInMessages,
                    icon: vm.searchingMessages
                        ? SizedBox(
                            width: context.sp(16),
                            height: context.sp(16),
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.manage_search_rounded),
                  ),
                ],
              ),
            ),
            if (vm.availableFolders().isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: context.sp(8)),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('All folders'),
                        selected: vm.activeFolder == null,
                        onSelected: (_) => ref
                            .read(chatListViewModelProvider(_args))
                            .setFolderFilter(null),
                      ),
                      ...vm.availableFolders().map((folder) => Padding(
                        padding: EdgeInsets.only(left: context.sp(8)),
                        child: FilterChip(
                          label: Text(_folderLabel(folder)),
                          selected: vm.activeFolder == folder,
                          onSelected: (_) => ref
                              .read(chatListViewModelProvider(_args))
                              .setFolderFilter(vm.activeFolder == folder ? null : folder),
                        ),
                      )),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: vm.loading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _loadChats,
                      child: showMessageHits
                          ? ListView.separated(
                              itemCount: vm.messageHits.length,
                              separatorBuilder: (_, index) =>
                                  SizedBox(height: context.sp(6)),
                              itemBuilder: (context, index) {
                                final hit = vm.messageHits[index];
                                return Card(
                                  child: ListTile(
                                    leading: const Icon(Icons.search_rounded),
                                    title: Text(hit.chatTitle),
                                    subtitle: Text(
                                      hit.content,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () async {
                                      final chat = items.firstWhere(
                                        (row) => row.id == hit.chatId,
                                        orElse: () => ChatItem(
                                          id: hit.chatId,
                                          title: hit.chatTitle,
                                          type: 'private',
                                          lastMessagePreview: hit.content,
                                          lastMessageAt: hit.createdAt,
                                          unreadCount: 0,
                                          isArchived: false,
                                          isPinned: false,
                                          folder: null,
                                          isSavedMessages: false,
                                        ),
                                      );
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
                                      await _loadChats();
                                    },
                                  ),
                                );
                              },
                            )
                          : items.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 120),
                                Center(child: Text('No chats yet')),
                              ],
                            )
                          : ListView.separated(
                              itemCount: items.length,
                              separatorBuilder: (_, index) =>
                                  SizedBox(height: context.sp(6)),
                              itemBuilder: (context, index) {
                                final chat = items[index];
                                return Dismissible(
                                  key: ValueKey('chat-${chat.id}'),
                                  direction: DismissDirection.horizontal,
                                  confirmDismiss: (direction) async {
                                    if (direction ==
                                        DismissDirection.startToEnd) {
                                      await _applyQuickChatAction(
                                        chat,
                                        isPinned: !chat.isPinned,
                                      );
                                      return false;
                                    }
                                    await _applyQuickChatAction(
                                      chat,
                                      isArchived: !chat.isArchived,
                                    );
                                    return false;
                                  },
                                  background: Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primaryContainer,
                                      borderRadius: BorderRadius.circular(
                                        context.sp(18),
                                      ),
                                    ),
                                    padding: EdgeInsets.symmetric(
                                      horizontal: context.sp(16),
                                    ),
                                    alignment: Alignment.centerLeft,
                                    child: Icon(
                                      chat.isPinned
                                          ? Icons.push_pin_outlined
                                          : Icons.push_pin_rounded,
                                    ),
                                  ),
                                  secondaryBackground: Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.secondaryContainer,
                                      borderRadius: BorderRadius.circular(
                                        context.sp(18),
                                      ),
                                    ),
                                    padding: EdgeInsets.symmetric(
                                      horizontal: context.sp(16),
                                    ),
                                    alignment: Alignment.centerRight,
                                    child: Icon(
                                      chat.isArchived
                                          ? Icons.unarchive_outlined
                                          : Icons.archive_outlined,
                                    ),
                                  ),
                                  child: _ChatTile(
                                    chat: chat,
                                    appearance: appearance,
                                    onTap: () async {
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
                                      await _loadChats();
                                    },
                                    onLongPress: () => _showChatActions(chat),
                                  ),
                                );
                              },
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final ChatItem chat;
  final AppAppearanceData appearance;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ChatTile({
    required this.chat,
    required this.appearance,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = chat.lastMessagePreview?.trim().isNotEmpty == true
        ? chat.lastMessagePreview!
        : 'No messages yet';
    final lastTime = chat.lastMessageAt;
    final avatarSize = appearance.compactChatList
        ? context.sp(46)
        : context.sp(56);
    final verticalPadding = appearance.compactChatList
        ? context.sp(10)
        : context.sp(14);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.sp(14),
            vertical: verticalPadding,
          ),
          child: Row(
            children: [
              SizedBox(
                width: avatarSize,
                height: avatarSize,
                child: CircleAvatar(
                  backgroundColor: appearance.accentColor.withValues(
                    alpha: 0.2,
                  ),
                  child: chat.isSavedMessages
                      ? Icon(
                          Icons.bookmark_rounded,
                          size: context.sp(22),
                          color: appearance.accentColor,
                        )
                      : Text(
                          chat.title.isEmpty
                              ? '?'
                              : chat.title.characters.first.toUpperCase(),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: context.sp(18),
                          ),
                        ),
                ),
              ),
              SizedBox(width: context.sp(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            chat.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: appearance.compactChatList
                                  ? context.sp(15)
                                  : context.sp(16),
                            ),
                          ),
                        ),
                        if (chat.isPinned)
                          Padding(
                            padding: EdgeInsets.only(left: context.sp(6)),
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: context.sp(14),
                              color: appearance.accentColor,
                            ),
                          ),
                        if (chat.isArchived)
                          Padding(
                            padding: EdgeInsets.only(left: context.sp(6)),
                            child: Icon(
                              Icons.archive_outlined,
                              size: context.sp(14),
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: context.sp(4)),
                    if (chat.folder != null && chat.folder!.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: context.sp(4)),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: context.sp(8),
                            vertical: context.sp(3),
                          ),
                          decoration: BoxDecoration(
                            color: appearance.accentColorMuted.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            chat.folder![0].toUpperCase() + chat.folder!.substring(1),
                            style: TextStyle(
                              fontSize: context.sp(10.5),
                              fontWeight: FontWeight.w600,
                              color: appearance.accentColor,
                            ),
                          ),
                        ),
                      ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: appearance.compactChatList
                            ? context.sp(12.5)
                            : context.sp(13.5),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: context.sp(12)),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (lastTime != null)
                    Text(
                      '${lastTime.hour.toString().padLeft(2, '0')}:${lastTime.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: context.sp(12),
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (chat.unreadCount > 0)
                    Container(
                      margin: EdgeInsets.only(top: context.sp(6)),
                      padding: EdgeInsets.symmetric(
                        horizontal: context.sp(8),
                        vertical: context.sp(3),
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: appearance.accentColor,
                      ),
                      child: Text(
                        '${chat.unreadCount}',
                        style: TextStyle(
                          color: const Color(0xFF111418),
                          fontWeight: FontWeight.w700,
                          fontSize: context.sp(11),
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
}

class ChatScreen extends ConsumerStatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final ChatItem chat;
  final AppUser me;

  const ChatScreen({
    super.key,
    required this.api,
    required this.getTokens,
    required this.chat,
    required this.me,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late ChatThreadVmArgs _threadArgs;
  final ChatDraftsLocalCache _drafts = ChatDraftsLocalCache();
  final ChatComposerQueueLocalCache _composerQueueCache =
      ChatComposerQueueLocalCache();
  final RealtimeCursorStore _cursorStore = RealtimeCursorStore();
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _composerFocusNode = FocusNode();
  final AudioRecorder _audioRecorder = AudioRecorder();

  RealtimeMeSocket? _realtime;
  Timer? _typingPauseTimer;
  Timer? _draftDebounce;
  Timer? _voiceTicker;
  bool _typingSent = false;
  bool _socketConnected = false;
  bool _voiceRecording = false;
  bool _voiceUploading = false;
  final Set<int> _typingUserIds = <int>{};
  final Map<int, double?> _attachmentDownloads = <int, double?>{};
  int _realtimeCursor = 0;
  int? _replyToMessageId;
  int? _editingMessageId;
  int _attachmentSeed = 0;
  DateTime? _voiceRecordingStartedAt;
  Duration _voiceRecordingDuration = Duration.zero;
  List<_PendingComposerAttachment> _pendingAttachments =
      const <_PendingComposerAttachment>[];
  final Map<int, GlobalKey> _messageKeys = <int, GlobalKey>{};
  final Set<int> _selectedMessageIds = <int>{};

  String _nextClientUploadId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'u_${widget.chat.id}_${widget.me.id}_$now';
  }

  @override
  void initState() {
    super.initState();
    _threadArgs = ChatThreadVmArgs(
      api: widget.api,
      getTokens: widget.getTokens,
      me: widget.me,
      chatId: widget.chat.id,
    );
    unawaited(ref.read(chatThreadViewModelProvider(_threadArgs)).prime());
    unawaited(_loadDraft());
    unawaited(_loadPendingAttachments());
    unawaited(_bootstrapRealtime());
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api.baseUrl != widget.api.baseUrl ||
        oldWidget.me.id != widget.me.id ||
        oldWidget.chat.id != widget.chat.id) {
      _threadArgs = ChatThreadVmArgs(
        api: widget.api,
        getTokens: widget.getTokens,
        me: widget.me,
        chatId: widget.chat.id,
      );
      unawaited(ref.read(chatThreadViewModelProvider(_threadArgs)).prime());
      _messageController.clear();
      _replyToMessageId = null;
      _editingMessageId = null;
      _pendingAttachments = const <_PendingComposerAttachment>[];
      _selectedMessageIds.clear();
      unawaited(_loadDraft());
      unawaited(_loadPendingAttachments());
      unawaited(_bootstrapRealtime());
    }
  }

  @override
  void dispose() {
    _notifyTypingStopped();
    _typingPauseTimer?.cancel();
    _draftDebounce?.cancel();
    _voiceTicker?.cancel();
    unawaited(_audioRecorder.dispose());
    _realtime?.stop();
    _messageController.dispose();
    _scrollController.dispose();
    _composerFocusNode.dispose();
    super.dispose();
  }

  Future<void> _openSharedMediaBrowser() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _SharedMediaBrowserPage(
          api: widget.api,
          getTokens: widget.getTokens,
          chat: widget.chat,
        ),
      ),
    );
  }

  Future<void> _loadDraft() async {
    final draft = await _drafts.loadDraft(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
      chatId: widget.chat.id,
    );
    if (!mounted || draft == null || draft.isEmpty) return;
    _messageController.text = draft;
    _messageController.selection = TextSelection.collapsed(
      offset: _messageController.text.length,
    );
    setState(() {});
  }

  void _scheduleDraftSave() {
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(
        _drafts.saveDraft(
          baseUrl: widget.api.baseUrl,
          userId: widget.me.id,
          chatId: widget.chat.id,
          text: _messageController.text,
        ),
      );
    });
  }

  Future<void> _clearDraft() async {
    _draftDebounce?.cancel();
    await _drafts.clearDraft(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
      chatId: widget.chat.id,
    );
  }

  Future<void> _loadPendingAttachments() async {
    final rows = await _composerQueueCache.loadQueue(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
      chatId: widget.chat.id,
    );
    if (!mounted || rows.isEmpty) return;

    final restored = rows
        .map(_PendingComposerAttachment.fromCacheJson)
        .where((item) => item.canRestoreIntoComposer)
        .toList();
    if (restored.isEmpty) {
      await _composerQueueCache.clearQueue(
        baseUrl: widget.api.baseUrl,
        userId: widget.me.id,
        chatId: widget.chat.id,
      );
      return;
    }

    final maxLocalId = restored.fold<int>(
      0,
      (current, item) => item.localId > current ? item.localId : current,
    );
    setState(() {
      _pendingAttachments = restored;
      _attachmentSeed = maxLocalId > _attachmentSeed ? maxLocalId : _attachmentSeed;
    });

    for (final item in restored) {
      if (item.shouldResumeUpload) {
        unawaited(_uploadAttachment(item.localId));
      }
    }
  }

  Future<void> _persistPendingAttachments() async {
    final restorable = _pendingAttachments
        .where((item) => item.canPersistInQueue)
        .map((item) => item.toCacheJson())
        .toList();
    await _composerQueueCache.saveQueue(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
      chatId: widget.chat.id,
      items: restorable,
    );
  }

  Future<void> _clearPendingAttachmentCache() async {
    await _composerQueueCache.clearQueue(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
      chatId: widget.chat.id,
    );
  }

  Future<void> _resetPendingAttachments() async {
    if (mounted) {
      setState(() {
        _pendingAttachments = const <_PendingComposerAttachment>[];
      });
    }
    await _clearPendingAttachmentCache();
  }

  List<MessageItem> get _messages {
    return ref.read(chatThreadViewModelProvider(_threadArgs)).messages;
  }

  bool get _sending {
    return ref.read(chatThreadViewModelProvider(_threadArgs)).sending;
  }

  bool get _hasUploadingAttachments {
    return _pendingAttachments.any((item) => item.isUploading);
  }

  bool get _hasFailedAttachments {
    return _pendingAttachments.any(
      (item) => item.errorMessage != null && !item.isReadyForSend,
    );
  }

  bool get _hasPreparingAttachments {
    return _pendingAttachments.any(
      (item) => !item.isReadyForSend && item.errorMessage == null,
    );
  }

  bool get _canTogglePendingSendMode {
    return _pendingAttachments.any((item) => item.canToggleSendMode);
  }

  bool get _pendingVisualAttachmentsAsFiles {
    final visual = _pendingAttachments.where((item) => item.canToggleSendMode).toList();
    if (visual.isEmpty) return false;
    return visual.every((item) => item.sendAsFile);
  }

  List<int> get _readyAttachmentIds {
    return _pendingAttachments
        .where((item) => item.isReadyForSend)
        .map((item) => item.uploadedAttachment?.id)
        .whereType<int>()
        .toList();
  }

  List<MessageAttachmentItem> get _readyUploadedAttachments {
    return _pendingAttachments
        .where((item) => item.isReadyForSend)
        .map((item) => item.uploadedAttachment)
        .whereType<MessageAttachmentItem>()
        .toList();
  }

  bool get _canSend {
    final hasPayload = _editingMessageId != null
        ? _messageController.text.trim().isNotEmpty
        : (_messageController.text.trim().isNotEmpty ||
              _readyAttachmentIds.isNotEmpty);
    return hasPayload &&
        !_voiceRecording &&
        !_voiceUploading &&
        !_hasUploadingAttachments &&
        !_hasPreparingAttachments &&
        !_hasFailedAttachments;
  }

  bool get _canRecordVoice {
    return !_voiceRecording &&
        !_voiceUploading &&
        !_hasUploadingAttachments &&
        _editingMessageId == null;
  }

  bool get _supportsQuickMediaCapture {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  MessageItem? _messageById(int messageId) {
    return ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .findMessageById(messageId);
  }

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  List<MessageItem> get _selectedMessages {
    final selected = _messages
        .where((message) => _selectedMessageIds.contains(message.id))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return selected;
  }

  void _toggleMessageSelection(MessageItem message) {
    setState(() {
      if (_selectedMessageIds.contains(message.id)) {
        _selectedMessageIds.remove(message.id);
      } else {
        _selectedMessageIds.add(message.id);
      }
    });
  }

  void _enterSelectionMode(MessageItem message) {
    setState(() {
      _selectedMessageIds.add(message.id);
    });
  }

  void _clearSelection() {
    if (_selectedMessageIds.isEmpty) return;
    setState(() {
      _selectedMessageIds.clear();
    });
  }

  void _pruneSelection() {
    if (_selectedMessageIds.isEmpty) return;
    final visibleIds = _messages.map((message) => message.id).toSet();
    final staleIds = _selectedMessageIds
        .where((messageId) => !visibleIds.contains(messageId))
        .toList();
    if (staleIds.isEmpty) return;
    setState(() {
      _selectedMessageIds.removeAll(staleIds);
    });
  }

  String _buildRealtimeUrl() {
    final tokens = widget.getTokens();
    if (tokens == null) return '';
    return '${webSocketBase(widget.api.baseUrl)}/api/realtime/me/ws?token=${Uri.encodeComponent(tokens.accessToken)}';
  }

  Future<void> _bootstrapRealtime() async {
    final cursor = await _cursorStore.loadCursor(
      baseUrl: widget.api.baseUrl,
      userId: widget.me.id,
    );
    if (!mounted) return;
    _realtimeCursor = cursor;
    _startRealtime();
  }

  void _startRealtime() {
    _realtime?.stop();
    _realtime = RealtimeMeSocket(
      urlBuilder: _buildRealtimeUrl,
      cursorGetter: () => _realtimeCursor,
      onEvent: _handleRealtimeEvent,
      onCursor: _rememberRealtimeCursor,
      onState: (state) {
        if (!mounted) return;
        final connected = state == RealtimeState.connected;
        if (_socketConnected != connected) {
          setState(() => _socketConnected = connected);
        }
        if (connected) {
          _ackUnreadMessages();
          unawaited(
            ref
                .read(chatThreadViewModelProvider(_threadArgs))
                .loadMessages(silent: true),
          );
        }
      },
    )..start();
  }

  void _rememberRealtimeCursor(int cursor) {
    if (cursor <= _realtimeCursor) return;
    _realtimeCursor = cursor;
    unawaited(
      _cursorStore.saveCursor(
        baseUrl: widget.api.baseUrl,
        userId: widget.me.id,
        cursor: cursor,
      ),
    );
  }

  bool _sendRealtime(Map<String, dynamic> payload) {
    return _realtime?.sendJson(payload) ?? false;
  }

  void _handleRealtimeEvent(Map<String, dynamic> map) {
    final type = map['type']?.toString();
    if (type == null || type.isEmpty) return;

    if (type == 'ready') {
      _ackUnreadMessages();
      unawaited(
        ref.read(chatThreadViewModelProvider(_threadArgs)).flushPendingOutbox(),
      );
      for (final item in _pendingAttachments) {
        if (item.shouldResumeUpload) {
          unawaited(_uploadAttachment(item.localId));
        }
      }
      return;
    }

    if (type == 'typing') {
      final chatId = map['chat_id'];
      final userId = map['user_id'];
      if (chatId is! int || userId is! int) return;
      if (chatId != widget.chat.id || userId == widget.me.id) return;
      final isTyping = (map['is_typing'] ?? false) == true;
      setState(() {
        if (isTyping) {
          _typingUserIds.add(userId);
        } else {
          _typingUserIds.remove(userId);
        }
      });
      return;
    }

    if (type == 'presence') {
      final chatId = map['chat_id'];
      final userId = map['user_id'];
      final status = (map['status'] ?? '').toString();
      if (chatId is! int || userId is! int) return;
      if (chatId != widget.chat.id || status != 'offline') return;
      setState(() => _typingUserIds.remove(userId));
      return;
    }

    if (type == 'message') {
      final chatId = map['chat_id'];
      if (chatId is! int || chatId != widget.chat.id) return;
      final message = map['message'];
      if (message is! Map) return;
      final item = MessageItem.fromJson(message.cast<String, dynamic>());
      final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
      vm.applyMessage(item);
      if (item.senderId == widget.me.id) {
        unawaited(vm.loadScheduledMessages(silent: true));
      }
      _scrollToBottom();
      _ackMessageRead(item);
      return;
    }

    if (type == 'message_updated') {
      final chatId = map['chat_id'];
      if (chatId is! int || chatId != widget.chat.id) return;
      final message = map['message'];
      if (message is! Map) return;
      final item = MessageItem.fromJson(message.cast<String, dynamic>());
      ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .applyUpdatedMessage(item);
      return;
    }

    if (type == 'message_deleted') {
      final chatId = map['chat_id'];
      final messageId = map['message_id'];
      if (chatId is! int || messageId is! int) return;
      if (chatId != widget.chat.id) return;
      if (_replyToMessageId == messageId || _editingMessageId == messageId) {
        _clearComposerMode();
      }
      ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .deleteMessage(messageId);
      return;
    }

    if (type == 'message_status') {
      final chatId = map['chat_id'];
      final messageId = map['message_id'];
      final senderStatus = map['sender_status']?.toString();
      if (chatId is! int || messageId is! int || senderStatus == null) return;
      if (chatId != widget.chat.id) return;
      ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .updateMessageStatus(messageId, senderStatus);
      return;
    }

    if (type == 'message_pinned' || type == 'message_unpinned') {
      final chatId = map['chat_id'];
      final messageId = map['message_id'];
      if (chatId is! int || messageId is! int) return;
      if (chatId != widget.chat.id) return;
      ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .updatePinnedState(
            messageId: messageId,
            pinned: type == 'message_pinned',
          );
      return;
    }

    if (type == 'reaction_added' || type == 'reaction_removed') {
      final chatId = map['chat_id'];
      if (chatId is! int || chatId != widget.chat.id) return;
      unawaited(
        ref
            .read(chatThreadViewModelProvider(_threadArgs))
            .loadMessages(silent: true),
      );
    }
  }

  void _ackUnreadMessages() {
    for (final message in _messages) {
      _ackMessageRead(message);
    }
  }

  void _ackMessageRead(MessageItem message) {
    if (message.chatId != widget.chat.id) return;
    if (message.senderId == widget.me.id) return;
    if (message.status == 'read') return;
    _sendRealtime({
      'type': 'seen',
      'chat_id': widget.chat.id,
      'message_id': message.id,
    });
  }

  void _onComposerChanged(String _) {
    final hasText = _messageController.text.trim().isNotEmpty;
    _scheduleDraftSave();
    if (hasText && !_typingSent) {
      _typingSent = true;
      _sendRealtime({
        'type': 'typing',
        'chat_id': widget.chat.id,
        'is_typing': true,
      });
    }

    _typingPauseTimer?.cancel();
    if (!hasText) {
      _notifyTypingStopped();
      if (mounted) setState(() {});
      return;
    }

    _typingPauseTimer = Timer(const Duration(seconds: 2), _notifyTypingStopped);
    if (mounted) setState(() {});
  }

  void _notifyTypingStopped() {
    _typingPauseTimer?.cancel();
    _typingPauseTimer = null;
    if (!_typingSent) return;
    _typingSent = false;
    _sendRealtime({
      'type': 'typing',
      'chat_id': widget.chat.id,
      'is_typing': false,
    });
  }

  Future<void> _startVoiceRecording() async {
    if (!_canRecordVoice) return;
    if (kIsWeb) {
      _showSnack('Voice messages are not available on web yet');
      return;
    }

    final granted = await _audioRecorder.hasPermission();
    if (!granted) {
      _showSnack('Microphone permission denied');
      return;
    }

    try {
      _notifyTypingStopped();
      _composerFocusNode.unfocus();
      final directory = await getTemporaryDirectory();
      final recordingPath =
          '${directory.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: recordingPath,
      );
      _voiceTicker?.cancel();
      final startedAt = DateTime.now();
      if (!mounted) return;
      setState(() {
        _voiceRecording = true;
        _voiceUploading = false;
        _voiceRecordingStartedAt = startedAt;
        _voiceRecordingDuration = Duration.zero;
      });
      _voiceTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        final base = _voiceRecordingStartedAt;
        if (!mounted || !_voiceRecording || base == null) return;
        setState(() {
          _voiceRecordingDuration = DateTime.now().difference(base);
        });
      });
    } catch (error) {
      _showSnack('Could not start voice recording');
    }
  }

  Future<void> _cancelVoiceRecording() async {
    if (!_voiceRecording) return;
    try {
      await _audioRecorder.cancel();
    } catch (_) {
      // Best-effort cleanup for temporary recording file.
    }
    _voiceTicker?.cancel();
    if (!mounted) return;
    setState(() {
      _voiceRecording = false;
      _voiceUploading = false;
      _voiceRecordingStartedAt = null;
      _voiceRecordingDuration = Duration.zero;
    });
  }

  Future<void> _finishVoiceRecording() async {
    if (!_voiceRecording) return;
    final tokens = widget.getTokens();
    if (tokens == null) {
      await _cancelVoiceRecording();
      _showSnack('Session expired');
      return;
    }

    String? recordingPath;
    try {
      recordingPath = await _audioRecorder.stop();
    } catch (_) {
      recordingPath = null;
    }

    _voiceTicker?.cancel();
    if (!mounted) return;
    setState(() {
      _voiceRecording = false;
      _voiceUploading = true;
      _voiceRecordingStartedAt = null;
      _voiceRecordingDuration = Duration.zero;
    });

    if (recordingPath == null || recordingPath.trim().isEmpty) {
      if (mounted) {
        setState(() => _voiceUploading = false);
      }
      _showSnack('Voice message was not recorded');
      return;
    }

    try {
      final uploaded = await widget.api.uploadChatMedia(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: widget.chat.id,
        fileName: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
        filePath: recordingPath,
        kindHint: 'voice',
        clientUploadId: _nextClientUploadId(),
      );
      final error = await ref
          .read(chatThreadViewModelProvider(_threadArgs))
          .sendMessage(
            '',
            attachmentIds: <int>[uploaded.id],
            attachments: <MessageAttachmentItem>[uploaded],
          );
      if (error != null) {
        _showSnack(error);
      } else {
        _scrollToBottom();
      }
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _voiceUploading = false);
      }
    }
  }

  Future<void> _sendMessage({
    String? textOverride,
    List<_PendingComposerAttachment>? attachmentsOverride,
    bool isSilent = false,
  }) async {
    final text = (textOverride ?? _messageController.text).trim();
    final attachments = attachmentsOverride ?? _pendingAttachments;
    if (attachmentsOverride != null) {
      await _resumePendingAttachmentPreparation();
    }
    final readyAttachmentIds = attachments
        .where((item) => item.isReadyForSend)
        .map((item) => item.uploadedAttachment?.id)
        .whereType<int>()
        .toList();
    final readyUploadedAttachments = attachments
        .where((item) => item.isReadyForSend)
        .map((item) => item.uploadedAttachment)
        .whereType<MessageAttachmentItem>()
        .toList();
    final canSend = _editingMessageId != null
        ? text.isNotEmpty
        : (text.isNotEmpty || readyAttachmentIds.isNotEmpty);
    if (!canSend || _hasUploadingAttachments || _hasPreparingAttachments || _hasFailedAttachments) {
      return;
    }
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final error = _editingMessageId != null
        ? await vm.editMessage(messageId: _editingMessageId!, text: text)
        : await vm.sendMessage(
            text,
            replyToMessageId: _replyToMessageId,
            attachmentIds: readyAttachmentIds,
            attachments: readyUploadedAttachments,
            isSilent: isSilent,
          );
    if (error == null) {
      _messageController.clear();
      _notifyTypingStopped();
      await _clearDraft();
      _clearComposerMode();
      await _resetPendingAttachments();
      _scrollToBottom();
      if (mounted) setState(() {});
      return;
    }
    _showSnack(error);
  }

  List<ChatAudioQueueItem> _buildAudioQueue() {
    final queue = <ChatAudioQueueItem>[];
    for (final message in _messages) {
      final timeLabel =
          '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}';
      final senderLabel = message.senderId == widget.me.id ? 'You' : widget.chat.title;
      for (final attachment in message.attachments.where((item) => item.isAudio)) {
        queue.add(
          ChatAudioQueueItem(
            attachment: attachment,
            audioUrl: widget.api.resolveUrl(attachment.url),
            title: attachment.displayLabel,
            subtitle: '$senderLabel • $timeLabel',
          ),
        );
      }
    }
    return queue;
  }

  Future<void> _openAudioViewer(MessageAttachmentItem attachment) async {
    final queue = _buildAudioQueue();
    if (queue.isEmpty) {
      _showSnack('No audio attachments available');
      return;
    }
    final initialIndex = queue.indexWhere(
      (item) => item.attachment.id == attachment.id,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChatAudioPlayerPage(
          queue: queue,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
        ),
      ),
    );
  }

  Future<DateTime?> _pickScheduleDateTime() async {
    final now = DateTime.now();
    final initial = now.add(const Duration(minutes: 1));
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (pickedDate == null || !mounted) return null;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (pickedTime == null) return null;

    final scheduledFor = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    if (!scheduledFor.isAfter(DateTime.now().add(const Duration(seconds: 5)))) {
      _showSnack('Choose a future date and time');
      return null;
    }
    return scheduledFor;
  }

  Future<void> _scheduleCurrentMessage({
    String? textOverride,
    List<_PendingComposerAttachment>? attachmentsOverride,
  }) async {
    if (_editingMessageId != null) {
      _showSnack('Finish editing before scheduling a message');
      return;
    }
    if (attachmentsOverride != null) {
      await _resumePendingAttachmentPreparation();
    }

    final scheduledFor = await _pickScheduleDateTime();
    if (scheduledFor == null) return;

    final text = (textOverride ?? _messageController.text).trim();
    final attachments = attachmentsOverride ?? _pendingAttachments;
    final readyAttachmentIds = attachments
        .where((item) => item.isReadyForSend)
        .map((item) => item.uploadedAttachment?.id)
        .whereType<int>()
        .toList();
    if ((text.isEmpty && readyAttachmentIds.isEmpty) ||
        _hasUploadingAttachments ||
        _hasPreparingAttachments ||
        _hasFailedAttachments) {
      return;
    }
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final error = await vm.sendScheduledMessage(
      text,
      scheduledFor: scheduledFor,
      replyToMessageId: _replyToMessageId,
      attachmentIds: readyAttachmentIds,
    );
    if (error == null) {
      _messageController.clear();
      _notifyTypingStopped();
      await _clearDraft();
      _clearComposerMode();
      await _resetPendingAttachments();
      _showSnack('Scheduled for ${_formatScheduledLabel(scheduledFor)}');
      return;
    }
    _showSnack(error);
  }

  Future<void> _scheduleCurrentMessageWhenOnline({
    String? textOverride,
    List<_PendingComposerAttachment>? attachmentsOverride,
  }) async {
    if (_editingMessageId != null) {
      _showSnack('Finish editing before scheduling a message');
      return;
    }
    if (widget.chat.type != 'private') {
      _showSnack('Send when online is only available in private chats');
      return;
    }
    if (attachmentsOverride != null) {
      await _resumePendingAttachmentPreparation();
    }

    final text = (textOverride ?? _messageController.text).trim();
    final attachments = attachmentsOverride ?? _pendingAttachments;
    final readyAttachmentIds = attachments
        .where((item) => item.isReadyForSend)
        .map((item) => item.uploadedAttachment?.id)
        .whereType<int>()
        .toList();
    if ((text.isEmpty && readyAttachmentIds.isEmpty) ||
        _hasUploadingAttachments ||
        _hasPreparingAttachments ||
        _hasFailedAttachments) {
      return;
    }

    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final error = await vm.sendScheduledMessage(
      text,
      sendWhenUserOnline: true,
      replyToMessageId: _replyToMessageId,
      attachmentIds: readyAttachmentIds,
    );
    if (error == null) {
      _messageController.clear();
      _notifyTypingStopped();
      await _clearDraft();
      _clearComposerMode();
      await _resetPendingAttachments();
      _showSnack('Will send when the recipient comes online');
      return;
    }
    _showSnack(error);
  }

  Future<void> _showScheduleOptions() async {
    if (_editingMessageId != null || !_canSend) return;

    if (widget.chat.type != 'private') {
      await _scheduleCurrentMessage();
      return;
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.schedule_send_rounded),
                title: const Text('Send at date and time'),
                subtitle: const Text('Choose an exact delivery moment'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _scheduleCurrentMessage();
                },
              ),
              ListTile(
                leading: const Icon(Icons.bolt_rounded),
                title: const Text('Send when online'),
                subtitle: const Text('Deliver as soon as the other person is online'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _scheduleCurrentMessageWhenOnline();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showQuickSendOptions() async {
    if (_editingMessageId != null || !_canSend || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Send silently'),
                subtitle: const Text('Deliver without a notification sound'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _sendMessage(isSilent: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule_send_rounded),
                title: const Text('Schedule message'),
                subtitle: const Text('Choose a delivery time'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _scheduleCurrentMessage();
                },
              ),
              if (widget.chat.type == 'private')
                ListTile(
                  leading: const Icon(Icons.bolt_rounded),
                  title: const Text('Send when online'),
                  subtitle: const Text('Deliver when the recipient appears online'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await _scheduleCurrentMessageWhenOnline();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showScheduledMessagesSheet() async {
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final error = await vm.loadScheduledMessages();
    if (error != null) {
      _showSnack(error);
      return;
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final currentVm = ref.watch(chatThreadViewModelProvider(_threadArgs));
            final rows = currentVm.scheduledMessages;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: context.sp(12),
                  right: context.sp(12),
                  top: context.sp(12),
                  bottom: context.sp(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Scheduled messages',
                          style: TextStyle(
                            fontSize: context.sp(18),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: () => unawaited(
                            ref
                                .read(chatThreadViewModelProvider(_threadArgs))
                                .loadScheduledMessages(),
                          ),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                    if (currentVm.loadingScheduled && rows.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(context.sp(24)),
                        child: const CircularProgressIndicator(),
                      )
                    else if (rows.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(context.sp(24)),
                        child: Text(
                          'No scheduled messages in this chat',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = rows[index];
                            final preview = item.content.trim().isNotEmpty
                                ? item.content.trim()
                                : item.hasAttachments
                                ? '${item.attachments.length} attachment(s)'
                                : 'Scheduled message';
                            return ListTile(
                              leading: CircleAvatar(
                                child: Icon(
                                  item.hasAttachments
                                      ? Icons.attach_file_rounded
                                      : Icons.schedule_send_rounded,
                                ),
                              ),
                              title: Text(
                                preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${item.sendWhenUserOnline ? 'When online' : _formatScheduledLabel(item.scheduledFor)}${item.attachments.isEmpty ? '' : ' • ${item.attachments.length} attachment(s)'}',
                              ),
                              trailing: IconButton(
                                tooltip: 'Cancel scheduled send',
                                onPressed: () async {
                                  final removeError = await ref
                                      .read(chatThreadViewModelProvider(_threadArgs))
                                      .cancelScheduledMessage(item.id);
                                  if (removeError != null) {
                                    _showSnack(removeError);
                                  }
                                },
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatScheduledLabel(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(local.year, local.month, local.day);
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (date == today) {
      return 'Today at $time';
    }
    if (date == today.add(const Duration(days: 1))) {
      return 'Tomorrow at $time';
    }
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} $time';
  }

  void _clearComposerMode() {
    if (!mounted) return;
    setState(() {
      _replyToMessageId = null;
      _editingMessageId = null;
    });
  }

  void _startReply(MessageItem message) {
    setState(() {
      _replyToMessageId = message.id;
      _editingMessageId = null;
    });
    _composerFocusNode.requestFocus();
  }

  void _startEdit(MessageItem message) {
    setState(() {
      _editingMessageId = message.id;
      _replyToMessageId = null;
      _pendingAttachments = const <_PendingComposerAttachment>[];
    });
    unawaited(_clearPendingAttachmentCache());
    _messageController.text = message.content;
    _messageController.selection = TextSelection.collapsed(
      offset: _messageController.text.length,
    );
    _onComposerChanged(_messageController.text);
    _composerFocusNode.requestFocus();
  }

  Future<void> _deleteMessage(MessageItem message) async {
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final isLocalPending = vm.isPendingLocalMessage(message);
    String? scope;
    if (isLocalPending) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cancel pending message'),
          content: const Text('This only removes the queued message from this device.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    } else {
      final canDeleteForEveryone = message.senderId == widget.me.id;
      scope = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Delete for me'),
                  onTap: () => Navigator.of(context).pop('me'),
                ),
                if (canDeleteForEveryone)
                  ListTile(
                    leading: const Icon(Icons.delete_forever_rounded),
                    title: const Text('Delete for everyone'),
                    onTap: () => Navigator.of(context).pop('all'),
                  ),
                ListTile(
                  leading: const Icon(Icons.close_rounded),
                  title: const Text('Cancel'),
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          );
        },
      );
      if (scope == null) return;
    }

    if (isLocalPending) {
      await vm.cancelPendingMessage(message);
    } else {
      final error = await vm.deleteRemoteMessage(message.id, scope: scope ?? 'all');
      if (error != null) {
        _showSnack(error);
        return;
      }
    }
    if (_replyToMessageId == message.id || _editingMessageId == message.id) {
      _clearComposerMode();
      _messageController.clear();
      await _clearDraft();
    }
  }

  Future<void> _togglePin(MessageItem message) async {
    final error = await ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .setMessagePinned(messageId: message.id, pinned: !message.isPinned);
    if (error != null) {
      _showSnack(error);
    }
  }

  Future<void> _showMessageActions(MessageItem message) async {
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final mine = message.senderId == widget.me.id;
    final isLocalPending = vm.isPendingLocalMessage(message);
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isLocalPending)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    context.sp(16),
                    context.sp(12),
                    context.sp(16),
                    context.sp(8),
                  ),
                  child: Row(
                    children: _kQuickReactionEmoji
                        .map(
                          (emoji) => Expanded(
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: context.sp(4),
                              ),
                              child: _QuickReactionButton(
                                emoji: emoji,
                                active: message.reactions.any(
                                  (reaction) =>
                                      reaction.emoji == emoji &&
                                      reaction.reactedByMe,
                                ),
                                onTap: () {
                                  Navigator.of(context).pop();
                                  unawaited(
                                    _toggleReaction(
                                      message: message,
                                      emoji: emoji,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLocalPending && message.status == 'failed')
                        ListTile(
                          leading: const Icon(Icons.refresh_rounded),
                          title: const Text('Retry send'),
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_retryPendingMessage(message));
                          },
                        ),
                      if (isLocalPending)
                        ListTile(
                          leading: const Icon(Icons.delete_outline_rounded),
                          title: const Text('Remove queued message'),
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_deleteMessage(message));
                          },
                        ),
                      if (!isLocalPending) ...[
                        ListTile(
                          leading: const Icon(Icons.reply_rounded),
                          title: const Text('Reply'),
                          onTap: () {
                            Navigator.of(context).pop();
                            _startReply(message);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.checklist_rounded),
                          title: const Text('Select'),
                          onTap: () {
                            Navigator.of(context).pop();
                            _enterSelectionMode(message);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.forward_rounded),
                          title: const Text('Forward'),
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_forwardMessage(message));
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.bookmark_add_outlined),
                          title: const Text('Save to Saved Messages'),
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_saveMessagesToSaved([message]));
                          },
                        ),
                        if (mine)
                          ListTile(
                            leading: const Icon(Icons.edit_outlined),
                            title: const Text('Edit'),
                            onTap: () {
                              Navigator.of(context).pop();
                              _startEdit(message);
                            },
                          ),
                        ListTile(
                          leading: Icon(
                            message.isPinned
                                ? Icons.push_pin_outlined
                                : Icons.push_pin_rounded,
                          ),
                          title: Text(
                            message.isPinned ? 'Unpin message' : 'Pin message',
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_togglePin(message));
                          },
                        ),
                        if (mine)
                          ListTile(
                            leading: const Icon(Icons.delete_outline_rounded),
                            title: const Text('Delete'),
                            onTap: () {
                              Navigator.of(context).pop();
                              unawaited(_deleteMessage(message));
                            },
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }


  Future<ChatItem?> _pickForwardTarget(List<MessageItem> sourceMessages) async {
    final tokens = widget.getTokens();
    if (tokens == null) return null;

    final chats = await widget.api.listChats(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      includeArchived: false,
    );
    final saved = await widget.api.openSavedMessagesChat(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    final combined = <ChatItem>[
      saved,
      ...chats.where((chat) => chat.id != saved.id),
    ];
    if (!mounted) return null;
    return showModalBottomSheet<ChatItem>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.sp(16),
                    vertical: context.sp(6),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      sourceMessages.length > 1 ? 'Forward messages to…' : 'Forward to…',
                      style: TextStyle(
                        fontSize: context.sp(18),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: combined.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final chat = combined[index];
                      return ListTile(
                        leading: CircleAvatar(
                          child: chat.isSavedMessages
                              ? const Icon(Icons.bookmark_rounded)
                              : Text(
                                  chat.title.isEmpty
                                      ? '?'
                                      : chat.title.characters.first.toUpperCase(),
                                ),
                        ),
                        title: Text(chat.title),
                        subtitle: chat.folder == null || chat.folder!.trim().isEmpty
                            ? null
                            : Text(_folderLabel(chat.folder!)),
                        onTap: () => Navigator.of(context).pop(chat),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _forwardMessages(
    List<MessageItem> sourceMessages, {
    ChatItem? fixedTarget,
    bool clearSelectionOnSuccess = false,
  }) async {
    final tokens = widget.getTokens();
    if (tokens == null) return;

    final ordered = [...sourceMessages]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (ordered.isEmpty) return;

    try {
      final target = fixedTarget ?? await _pickForwardTarget(ordered);
      if (target == null) return;

      String? firstError;
      final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
      for (final message in ordered) {
        if (target.id == widget.chat.id) {
          firstError ??= await vm.sendMessage(
            '',
            forwardFromMessageId: message.id,
          );
        } else {
          try {
            await widget.api.sendMessage(
              accessToken: tokens.accessToken,
              refreshToken: tokens.refreshToken,
              chatId: target.id,
              content: '',
              forwardFromMessageId: message.id,
            );
          } catch (error) {
            firstError ??= error.toString();
          }
        }
      }
      if (firstError != null) {
        _showSnack(firstError);
        return;
      }
      if (clearSelectionOnSuccess) {
        _clearSelection();
      }
      final count = ordered.length;
      _showSnack(
        count == 1
            ? 'Forwarded to ${target.title}'
            : 'Forwarded $count messages to ${target.title}',
      );
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _forwardMessage(MessageItem message) async {
    await _forwardMessages([message]);
  }

  Future<void> _saveMessagesToSaved(List<MessageItem> sourceMessages) async {
    final tokens = widget.getTokens();
    if (tokens == null) return;
    try {
      final saved = await widget.api.openSavedMessagesChat(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      await _forwardMessages(
        sourceMessages,
        fixedTarget: saved,
        clearSelectionOnSuccess: sourceMessages.length > 1,
      );
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  Future<void> _deleteSelectedMessages() async {
    final selected = _selectedMessages;
    if (selected.isEmpty) return;
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final canDeleteForEveryone = selected.every(
      (message) => vm.isPendingLocalMessage(message) || message.senderId == widget.me.id,
    );
    final scope = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: Text(selected.length == 1 ? 'Delete for me' : 'Delete selected for me'),
                onTap: () => Navigator.of(context).pop('me'),
              ),
              if (canDeleteForEveryone)
                ListTile(
                  leading: const Icon(Icons.delete_forever_outlined),
                  title: Text(selected.length == 1 ? 'Delete for everyone' : 'Delete selected for everyone'),
                  onTap: () => Navigator.of(context).pop('all'),
                ),
            ],
          ),
        );
      },
    );
    if (scope == null) return;

    String? firstError;
    for (final message in selected) {
      if (vm.isPendingLocalMessage(message)) {
        await vm.cancelPendingMessage(message);
        continue;
      }
      firstError ??= await vm.deleteRemoteMessage(message.id, scope: scope);
    }
    _pruneSelection();
    _clearSelection();
    if (firstError != null) {
      _showSnack(firstError);
      return;
    }
    _showSnack(
      selected.length == 1
          ? 'Message deleted'
          : '${selected.length} messages deleted',
    );
  }

  Future<void> _retryPendingMessage(MessageItem message) async {
    final error = await ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .retryFailedMessage(message: message);
    if (error != null) {
      _showSnack(error);
      return;
    }
    _showSnack('Queued to retry');
  }

  Future<void> _showAttachOptions() async {
    if (!_supportsQuickMediaCapture) {
      await _pickAttachments();
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Gallery'),
                subtitle: const Text('Pick photos and videos to send as an album'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_pickGalleryMedia());
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Camera'),
                subtitle: const Text('Capture a photo now'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_capturePhoto());
                },
              ),
              ListTile(
                leading: const Icon(Icons.attach_file_rounded),
                title: const Text('Files'),
                subtitle: const Text('Browse documents and media files'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_pickAttachments());
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickAttachments() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty || !mounted) return;

    final selected = result.files.map((file) {
      final localId = ++_attachmentSeed;
      return _PendingComposerAttachment.fromPlatformFile(
        localId: localId,
        clientUploadId: _nextClientUploadId(),
        file: file,
      );
    }).toList();

    _queuePendingAttachments(selected);
  }

  Future<void> _pickGalleryMedia() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.media,
        allowMultiple: true,
        withData: kIsWeb,
      );
      if (result != null && result.files.isNotEmpty && mounted) {
        final selected = result.files
            .map(
              (file) => _PendingComposerAttachment.fromPlatformFile(
                localId: ++_attachmentSeed,
                clientUploadId: _nextClientUploadId(),
                file: file,
              ),
            )
            .where((item) => item.isImage || item.isVideo)
            .toList();
        if (selected.isNotEmpty) {
          _queuePendingAttachments(selected);
          return;
        }
      }
    } catch (_) {}

    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 92);
    if (picked.isEmpty || !mounted) return;

    final prepared = <_PendingComposerAttachment>[];
    for (final file in picked) {
      final pending = await _pendingFromXFile(
        file: file,
        fallbackName: 'gallery_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      if (pending != null) {
        prepared.add(pending);
      }
    }
    if (prepared.isEmpty || !mounted) return;
    _queuePendingAttachments(prepared);
  }

  Future<void> _capturePhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: 90,
    );
    if (picked == null || !mounted) return;

    final pending = await _pendingFromXFile(
      file: picked,
      fallbackName: 'camera_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    if (pending == null || !mounted) return;
    _queuePendingAttachments(<_PendingComposerAttachment>[pending]);
  }

  Future<_PendingComposerAttachment?> _pendingFromXFile({
    required XFile file,
    required String fallbackName,
  }) async {
    try {
      final filePath = file.path.trim();
      final bytes = kIsWeb || filePath.isEmpty
          ? await file.readAsBytes()
          : null;
      final size = await file.length();
      return _PendingComposerAttachment(
        localId: ++_attachmentSeed,
        clientUploadId: _nextClientUploadId(),
        name: file.name.isEmpty ? fallbackName : file.name,
        sizeBytes: size,
        isImage: true,
        isAudio: false,
        isVideo: false,
        sendAsFile: false,
        filePath: filePath.isEmpty ? null : filePath,
        bytes: bytes,
        isUploading: true,
        errorMessage: null,
        uploadedAttachment: null,
      );
    } catch (error) {
      _showSnack('Could not prepare picked media');
      return null;
    }
  }

  void _queuePendingAttachments(List<_PendingComposerAttachment> selected) {
    if (selected.isEmpty || !mounted) return;
    setState(() {
      _pendingAttachments = [..._pendingAttachments, ...selected];
    });
    unawaited(_persistPendingAttachments());
    for (final item in selected) {
      unawaited(_uploadAttachment(item.localId));
    }
  }

  Future<void> _uploadAttachment(int localId) async {
    final tokens = widget.getTokens();
    if (tokens == null) {
      _updatePendingAttachment(
        localId,
        (item) =>
            item.copyWith(isUploading: false, errorMessage: 'Session expired'),
      );
      return;
    }

    final current = _pendingAttachments.where(
      (item) => item.localId == localId,
    );
    if (current.isEmpty) return;

    _updatePendingAttachment(
      localId,
      (item) => item.copyWith(isUploading: true, errorMessage: null),
    );

    final item = current.first;
    try {
      final uploaded = await widget.api.uploadChatMedia(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: widget.chat.id,
        fileName: item.name,
        filePath: item.filePath,
        bytes: item.bytes,
        kindHint: item.desiredKindHint,
        clientUploadId: item.clientUploadId,
      );
      _updatePendingAttachment(
        localId,
        (pending) => pending.copyWith(
          isUploading: false,
          uploadedAttachment: uploaded,
          errorMessage: null,
        ),
      );
    } catch (error) {
      _updatePendingAttachment(
        localId,
        (pending) => pending.copyWith(
          isUploading: false,
          errorMessage: error.toString(),
        ),
      );
    }
  }

  void _updatePendingAttachment(
    int localId,
    _PendingComposerAttachment Function(_PendingComposerAttachment current)
    transform,
  ) {
    if (!mounted) return;
    setState(() {
      _pendingAttachments = _pendingAttachments.map((item) {
        if (item.localId != localId) return item;
        return transform(item);
      }).toList();
    });
    unawaited(_persistPendingAttachments());
  }

  void _removePendingAttachment(int localId) {
    if (!mounted) return;
    setState(() {
      _pendingAttachments = _pendingAttachments
          .where((item) => item.localId != localId)
          .toList();
    });
    unawaited(_persistPendingAttachments());
  }

  Future<void> _retryAttachment(_PendingComposerAttachment item) async {
    await _uploadAttachment(item.localId);
  }

  void _setAllPendingVisualAttachmentsSendAsFile(bool value) {
    if (!mounted || !_canTogglePendingSendMode) return;
    final normalized = _normalizePendingAttachmentsForApply(
      _pendingAttachments
          .map(
            (item) => item.canToggleSendMode
                ? item.copyWith(sendAsFile: value)
                : item,
          )
          .toList(),
    );
    setState(() {
      _pendingAttachments = normalized;
    });
    unawaited(_persistPendingAttachments());
    for (final item in normalized) {
      if (item.shouldResumeUpload) {
        unawaited(_uploadAttachment(item.localId));
      }
    }
  }

  List<_PendingComposerAttachment> _normalizePendingAttachmentsForApply(
    List<_PendingComposerAttachment> next,
  ) {
    final previousByLocalId = {
      for (final item in _pendingAttachments) item.localId: item,
    };
    return next.map((item) {
      final previous = previousByLocalId[item.localId];
      if (previous == null) return item;
      if (previous.sendAsFile == item.sendAsFile || !item.canToggleSendMode) {
        return item;
      }
      return item.copyWith(
        clientUploadId: _nextClientUploadId(),
        isUploading: false,
        errorMessage: null,
      );
    }).toList();
  }

  Future<void> _resumePendingAttachmentPreparation() async {
    final pendingIds = _pendingAttachments
        .where((item) => item.shouldResumeUpload)
        .map((item) => item.localId)
        .toList();
    for (final localId in pendingIds) {
      await _uploadAttachment(localId);
    }
  }

  void _reorderPendingAttachments(int oldIndex, int newIndex) {
    if (!mounted) return;
    if (oldIndex < 0 || oldIndex >= _pendingAttachments.length) return;
    if (newIndex < 0 || newIndex > _pendingAttachments.length) return;
    setState(() {
      final items = [..._pendingAttachments];
      if (newIndex > oldIndex) newIndex -= 1;
      final item = items.removeAt(oldIndex);
      items.insert(newIndex, item);
      _pendingAttachments = items;
    });
    unawaited(_persistPendingAttachments());
  }

  Future<void> _openPendingMediaComposer({int initialIndex = 0}) async {
    if (_pendingAttachments.isEmpty) return;
    final result = await Navigator.of(context).push<_PendingComposerEditorResult>(
      MaterialPageRoute<_PendingComposerEditorResult>(
        builder: (context) => _PendingComposerEditorPage(
          attachments: _pendingAttachments,
          initialIndex: initialIndex,
          resolveUrl: widget.api.resolveUrl,
          initialCaption: _messageController.text,
          chatTitle: widget.chat.title,
          allowSendWhenOnline: widget.chat.type == 'private',
        ),
      ),
    );
    if (result == null || !mounted) return;
    final normalizedAttachments = _normalizePendingAttachmentsForApply(
      result.attachments,
    );
    setState(() {
      _pendingAttachments = normalizedAttachments;
      _messageController.text = result.caption;
      _messageController.selection = TextSelection.collapsed(
        offset: _messageController.text.length,
      );
    });
    _scheduleDraftSave();
    await _persistPendingAttachments();
    for (final item in normalizedAttachments) {
      if (item.shouldResumeUpload) {
        unawaited(_uploadAttachment(item.localId));
      }
    }

    switch (result.action) {
      case _PendingComposerAction.apply:
        return;
      case _PendingComposerAction.sendNow:
        await _sendMessage(
          textOverride: result.caption,
          attachmentsOverride: normalizedAttachments,
        );
        return;
      case _PendingComposerAction.sendSilently:
        await _sendMessage(
          textOverride: result.caption,
          attachmentsOverride: normalizedAttachments,
          isSilent: true,
        );
        return;
      case _PendingComposerAction.scheduleAt:
        await _scheduleCurrentMessage(
          textOverride: result.caption,
          attachmentsOverride: normalizedAttachments,
        );
        return;
      case _PendingComposerAction.sendWhenOnline:
        await _scheduleCurrentMessageWhenOnline(
          textOverride: result.caption,
          attachmentsOverride: normalizedAttachments,
        );
        return;
    }
  }

  Future<void> _openAttachment(MessageAttachmentItem attachment) async {
    if (attachment.isImage) {
      await _openImageViewer(attachment);
      return;
    }
    if (attachment.isVideo) {
      await _openVideoViewer(attachment);
      return;
    }
    if (attachment.isAudio) {
      await _openAudioViewer(attachment);
      return;
    }

    final resolvedUrl = widget.api.resolveUrl(attachment.url);
    final uri = Uri.tryParse(resolvedUrl);
    if (uri == null) {
      _showSnack('Attachment URL is invalid');
      return;
    }

    if (_attachmentDownloads.containsKey(attachment.id)) {
      return;
    }

    try {
      final cachedFile = await AstraAttachmentCache.instance.getCachedFile(
        resolvedUrl,
      );
      if (cachedFile != null) {
        await _openLocalAttachment(cachedFile);
        return;
      }

      if (mounted) {
        setState(() => _attachmentDownloads[attachment.id] = 0);
      }

      File? downloadedFile;
      await for (final event in AstraAttachmentCache.instance.download(
        resolvedUrl,
        mediaClass: attachment.mediaKind,
        fileName: attachment.fileName,
        chatId: widget.chat.id,
        chatTitle: widget.chat.title,
        attachmentId: attachment.id,
      )) {
        if (!mounted) break;
        if (event.file != null) {
          downloadedFile = event.file;
          setState(() => _attachmentDownloads.remove(attachment.id));
          break;
        }
        setState(() {
          _attachmentDownloads[attachment.id] = event.progress?.clamp(0, 1);
        });
      }

      if (downloadedFile != null) {
        await _openLocalAttachment(downloadedFile);
        return;
      }

      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        _showSnack('Could not open attachment');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _attachmentDownloads.remove(attachment.id));
      }
      _showSnack('Could not download attachment');
    }
  }

  Future<void> _openImageViewer(MessageAttachmentItem attachment) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChatPhotoViewerPage(
          attachment: attachment,
          imageUrl: widget.api.resolveUrl(attachment.url),
        ),
      ),
    );
  }

  Future<void> _openVideoViewer(MessageAttachmentItem attachment) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChatVideoViewerPage(
          attachment: attachment,
          videoUrl: widget.api.resolveUrl(attachment.url),
        ),
      ),
    );
  }

  Future<void> _openMessageMediaAlbum(
    List<MessageAttachmentItem> attachments, {
    int initialIndex = 0,
  }) async {
    final mediaItems = attachments
        .where((item) => item.isImage || item.isVideo)
        .map(
          (attachment) => ChatGalleryEntry(
            attachment: attachment,
            mediaUrl: widget.api.resolveUrl(attachment.url),
            previewUrl: attachment.thumbnailUrl == null ||
                    attachment.thumbnailUrl!.trim().isEmpty
                ? widget.api.resolveUrl(attachment.url)
                : widget.api.resolveUrl(attachment.thumbnailUrl!),
          ),
        )
        .toList();
    if (mediaItems.isEmpty) return;
    final safeIndex = initialIndex.clamp(0, mediaItems.length - 1);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChatMediaGalleryPage(
          items: mediaItems,
          initialIndex: safeIndex,
        ),
      ),
    );
  }

  Future<void> _openLocalAttachment(File file) async {
    if (kIsWeb) {
      final uri = Uri.file(file.path);
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        _showSnack('Could not open attachment');
      }
      return;
    }

    final result = await OpenFile.open(file.path);
    if (result.type != ResultType.done) {
      _showSnack('Could not open attachment');
    }
  }

  Future<void> _toggleReaction({
    required MessageItem message,
    required String emoji,
    bool? reactedByMe,
  }) async {
    final existing = message.reactions.where((item) => item.emoji == emoji);
    final alreadyReacted =
        reactedByMe ?? (existing.isNotEmpty && existing.first.reactedByMe);
    final error = await ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .toggleReaction(
          messageId: message.id,
          emoji: emoji,
          reactedByMe: alreadyReacted,
        );
    if (error != null) {
      _showSnack(error);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels <= context.sp(96)) {
      unawaited(_loadMoreHistory());
    }
  }

  Future<void> _loadMoreHistory() async {
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    if (vm.loadingMore || vm.nextBeforeId == null) return;

    final hadClients = _scrollController.hasClients;
    final previousOffset = hadClients ? _scrollController.offset : 0.0;
    final previousExtent = hadClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;

    final error = await vm.loadMoreHistory();
    if (error != null) {
      _showSnack(error);
      return;
    }

    if (!hadClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final delta = _scrollController.position.maxScrollExtent - previousExtent;
      final targetOffset = previousOffset + delta;
      _scrollController.jumpTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + context.sp(30),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  GlobalKey _messageKey(int messageId) {
    return _messageKeys.putIfAbsent(messageId, GlobalKey.new);
  }

  Future<void> _jumpToMessage(int messageId) async {
    final vm = ref.read(chatThreadViewModelProvider(_threadArgs));
    final error = await vm.openMessageContext(messageId);
    if (error != null) {
      _showSnack(error);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = _messageKeys[messageId]?.currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 250),
          alignment: 0.35,
          curve: Curves.easeInOut,
        );
      }
    });
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      ref.read(chatThreadViewModelProvider(_threadArgs)).clearHighlightedMessage();
    });
  }

  Future<void> _showInChatSearchSheet() async {
    final controller = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              context.sp(16),
              context.sp(8),
              context.sp(16),
              MediaQuery.of(context).viewInsets.bottom + context.sp(16),
            ),
            child: Consumer(
              builder: (context, ref, _) {
                final vm = ref.watch(chatThreadViewModelProvider(_threadArgs));
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Search in chat',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SizedBox(height: context.sp(12)),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onChanged: (value) {
                        unawaited(ref
                            .read(chatThreadViewModelProvider(_threadArgs))
                            .searchInCurrentChat(value));
                      },
                      onSubmitted: (value) {
                        unawaited(ref
                            .read(chatThreadViewModelProvider(_threadArgs))
                            .searchInCurrentChat(value));
                      },
                      decoration: const InputDecoration(
                        hintText: 'Search messages',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                    ),
                    SizedBox(height: context.sp(12)),
                    if (vm.searchingInChat)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (controller.text.trim().length >= 2 &&
                        vm.chatMessageHits.isEmpty)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: context.sp(12)),
                        child: const Center(child: Text('Nothing found')), 
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: vm.chatMessageHits.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final hit = vm.chatMessageHits[index];
                            return ListTile(
                              leading: const Icon(Icons.search_rounded),
                              title: Text(
                                hit.content.trim().isEmpty ? 'Media message' : hit.content,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(_formatMessageTimestamp(hit.createdAt)),
                              onTap: () {
                                Navigator.of(context).pop();
                                unawaited(_jumpToMessage(hit.messageId));
                              },
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
    controller.dispose();
    if (!mounted) return;
    ref.read(chatThreadViewModelProvider(_threadArgs)).clearInChatSearch();
  }

  Future<void> _clearHistoryForMe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history for me'),
        content: const Text(
          'This removes the visible message history only on this device/account. Other chat members will keep their messages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await ref
        .read(chatThreadViewModelProvider(_threadArgs))
        .clearHistoryForMe();
    if (error != null) {
      _showSnack(error);
      return;
    }
    _clearComposerMode();
    _messageController.clear();
    await _clearDraft();
    _showSnack('History cleared for you');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(chatThreadViewModelProvider(_threadArgs));
    final appearance = ref.watch(appPreferencesProvider).appearance;
    final pinnedMessage = vm.pinnedMessage;
    final replyTarget = _replyToMessageId == null
        ? null
        : _messageById(_replyToMessageId!);
    final editingTarget = _editingMessageId == null
        ? null
        : _messageById(_editingMessageId!);
    final scheduledCount = vm.scheduledMessages.length;

    return Scaffold(
      appBar: AppBar(
        leading: _selectionMode
            ? IconButton(
                tooltip: 'Cancel selection',
                onPressed: _clearSelection,
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        title: Text(_selectionMode ? '${_selectedMessages.length} selected' : widget.chat.title),
        actions: _selectionMode
            ? [
                IconButton(
                  tooltip: 'Forward selected',
                  onPressed: _selectedMessages.isEmpty
                      ? null
                      : () => unawaited(_forwardMessages(_selectedMessages, clearSelectionOnSuccess: true)),
                  icon: const Icon(Icons.forward_rounded),
                ),
                IconButton(
                  tooltip: 'Save to Saved Messages',
                  onPressed: _selectedMessages.isEmpty
                      ? null
                      : () => unawaited(_saveMessagesToSaved(_selectedMessages)),
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
                IconButton(
                  tooltip: 'Delete selected',
                  onPressed: _selectedMessages.isEmpty
                      ? null
                      : () => unawaited(_deleteSelectedMessages()),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Search in chat',
                  onPressed: _showInChatSearchSheet,
                  icon: const Icon(Icons.search_rounded),
                ),
                IconButton(
                  tooltip: 'Shared media',
                  onPressed: _openSharedMediaBrowser,
                  icon: const Icon(Icons.perm_media_rounded),
                ),
                IconButton(
                  tooltip: 'Scheduled messages',
                  onPressed: _showScheduledMessagesSheet,
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.schedule_send_rounded),
                      if (scheduledCount > 0)
                        Positioned(
                          right: -6,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              scheduledCount > 99 ? '99+' : '$scheduledCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'clear_history') {
                      unawaited(_clearHistoryForMe());
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'clear_history',
                      child: Text('Clear history for me'),
                    ),
                  ],
                ),
                Icon(
                  _socketConnected
                      ? Icons.wifi_tethering_rounded
                      : Icons.wifi_tethering_off_rounded,
                  color: _socketConnected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
                SizedBox(width: context.sp(12)),
              ],
        bottom: _selectionMode || _typingUserIds.isEmpty
            ? null
            : PreferredSize(
                preferredSize: Size.fromHeight(context.sp(20)),
                child: Padding(
                  padding: EdgeInsets.only(bottom: context.sp(6)),
                  child: Text(
                    'typing...',
                    style: TextStyle(
                      fontSize: context.sp(13),
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: appearance.chatBackgroundGradient),
        child: Column(
          children: [
            if (pinnedMessage != null)
              Container(
                margin: EdgeInsets.fromLTRB(
                  context.sp(12),
                  context.sp(10),
                  context.sp(12),
                  0,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: context.sp(12),
                  vertical: context.sp(10),
                ),
                decoration: BoxDecoration(
                  color: appearance.surfaceColor.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(context.sp(16)),
                  border: Border.all(color: appearance.outlineColor),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.push_pin_rounded,
                      size: context.sp(18),
                      color: appearance.accentColor,
                    ),
                    SizedBox(width: context.sp(10)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pinned message',
                            style: TextStyle(
                              fontSize: context.sp(12),
                              fontWeight: FontWeight.w700,
                              color: appearance.accentColor,
                            ),
                          ),
                          SizedBox(height: context.sp(2)),
                          Text(
                            pinnedMessage.content.trim().isEmpty
                                ? 'Pinned media message'
                                : pinnedMessage.content,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Unpin',
                      onPressed: () => unawaited(_togglePin(pinnedMessage)),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: vm.loading
                  ? const Center(child: CircularProgressIndicator())
                  : vm.messages.isEmpty
                  ? Center(
                      child: Text(
                        'No messages yet. Start the conversation.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.symmetric(
                        horizontal: context.sp(12),
                        vertical: context.sp(10),
                      ),
                      itemCount: vm.messages.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          if (vm.loadingMore) {
                            return Padding(
                              padding: EdgeInsets.only(bottom: context.sp(8)),
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            );
                          }
                          if (vm.nextBeforeId != null) {
                            return Padding(
                              padding: EdgeInsets.only(bottom: context.sp(8)),
                              child: Center(
                                child: OutlinedButton.icon(
                                  onPressed: _loadMoreHistory,
                                  icon: const Icon(Icons.history_rounded),
                                  label: const Text('Load earlier messages'),
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }

                        final message = vm.messages[index - 1];
                        final mine = message.senderId == widget.me.id;
                        return _MessageBubble(
                          key: _messageKey(message.id),
                          message: message,
                          repliedMessage: message.replyToMessageId == null
                              ? null
                              : vm.findMessageById(message.replyToMessageId!),
                          mine: mine,
                          appearance: appearance,
                          highlighted: vm.highlightedMessageId == message.id,
                          selected: _selectedMessageIds.contains(message.id),
                          onTap: _selectionMode
                              ? () => _toggleMessageSelection(message)
                              : null,
                          onLongPress: () => _selectionMode
                              ? _toggleMessageSelection(message)
                              : _showMessageActions(message),
                          attachmentUrlBuilder: widget.api.resolveUrl,
                          onAttachmentTap: _openAttachment,
                          onMediaAlbumTap: (attachments, initialIndex) =>
                              _openMessageMediaAlbum(
                                attachments,
                                initialIndex: initialIndex,
                              ),
                          attachmentDownloadProgressLookup: (attachmentId) =>
                              _attachmentDownloads[attachmentId],
                          onReactionTap: (emoji, reactedByMe) =>
                              _toggleReaction(
                                message: message,
                                emoji: emoji,
                                reactedByMe: reactedByMe,
                              ),
                          onReplyPreviewTap: message.replyToMessageId == null
                              ? null
                              : () => _jumpToMessage(message.replyToMessageId!),
                        );
                      },
                    ),
            ),
            if (!_selectionMode)
              SafeArea(
                top: false,
                child: Container(
                padding: EdgeInsets.fromLTRB(
                  context.sp(10),
                  context.sp(8),
                  context.sp(10),
                  context.sp(10),
                ),
                decoration: BoxDecoration(
                  color: appearance.surfaceColor.withValues(alpha: 0.94),
                  border: Border(
                    top: BorderSide(color: appearance.outlineColor),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_editingMessageId != null || _replyToMessageId != null)
                      Container(
                        width: double.infinity,
                        margin: EdgeInsets.only(bottom: context.sp(8)),
                        padding: EdgeInsets.symmetric(
                          horizontal: context.sp(12),
                          vertical: context.sp(10),
                        ),
                        decoration: BoxDecoration(
                          color: appearance.accentColorMuted.withValues(
                            alpha: 0.84,
                          ),
                          borderRadius: BorderRadius.circular(context.sp(14)),
                          border: Border.all(color: appearance.outlineColor),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _editingMessageId != null
                                  ? Icons.edit_outlined
                                  : Icons.reply_rounded,
                              size: context.sp(18),
                              color: appearance.accentColor,
                            ),
                            SizedBox(width: context.sp(10)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _editingMessageId != null
                                        ? 'Editing message'
                                        : 'Replying',
                                    style: TextStyle(
                                      fontSize: context.sp(12),
                                      fontWeight: FontWeight.w700,
                                      color: appearance.accentColor,
                                    ),
                                  ),
                                  SizedBox(height: context.sp(2)),
                                  Text(
                                    (_editingMessageId != null
                                                    ? editingTarget?.content
                                                    : replyTarget?.content)
                                                ?.trim()
                                                .isNotEmpty ==
                                            true
                                        ? (_editingMessageId != null
                                              ? editingTarget!.content
                                              : replyTarget!.content)
                                        : 'Selected message',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: _clearComposerMode,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                    if (_pendingAttachments.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: context.sp(8)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _pendingAttachments.length > 1 &&
                                                _pendingAttachments.every(
                                                  (item) => item.isVisualMediaForSend,
                                                )
                                            ? 'Album • ${_pendingAttachments.length} items'
                                            : _pendingAttachments.length == 1
                                            ? '1 attachment selected'
                                            : '${_pendingAttachments.length} attachments selected',
                                        style: TextStyle(
                                          fontSize: context.sp(12),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      SizedBox(height: context.sp(2)),
                                      Text(
                                        _hasUploadingAttachments
                                            ? 'Finish uploads before sending. Drag to reorder or open preview to add a shared caption.'
                                            : _hasPreparingAttachments
                                            ? 'Applying the selected send mode. Hold Send for silent or scheduled delivery.'
                                            : 'Drag to reorder or open preview to add a shared caption. Hold Send for more options.',
                                        style: TextStyle(
                                          fontSize: context.sp(11),
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_canTogglePendingSendMode)
                                  TextButton.icon(
                                    onPressed: () => _setAllPendingVisualAttachmentsSendAsFile(
                                      !_pendingVisualAttachmentsAsFiles,
                                    ),
                                    icon: Icon(
                                      _pendingVisualAttachmentsAsFiles
                                          ? Icons.file_present_rounded
                                          : Icons.auto_awesome_rounded,
                                    ),
                                    label: Text(
                                      _pendingVisualAttachmentsAsFiles
                                          ? 'As files'
                                          : 'Compressed',
                                    ),
                                  ),
                                TextButton.icon(
                                  onPressed: () => _openPendingMediaComposer(),
                                  icon: const Icon(Icons.photo_library_outlined),
                                  label: const Text('Preview'),
                                ),
                              ],
                            ),
                            SizedBox(height: context.sp(8)),
                            SizedBox(
                              height: context.sp(152),
                              child: ReorderableListView.builder(
                                scrollDirection: Axis.horizontal,
                                buildDefaultDragHandles: false,
                                itemCount: _pendingAttachments.length,
                                onReorder: _reorderPendingAttachments,
                                proxyDecorator: (child, index, animation) => Material(
                                  color: Colors.transparent,
                                  elevation: 6,
                                  child: child,
                                ),
                                itemBuilder: (context, index) {
                                  final attachment = _pendingAttachments[index];
                                  return Container(
                                    key: ValueKey(attachment.localId),
                                    width: context.sp(148),
                                    margin: EdgeInsets.only(
                                      right: index == _pendingAttachments.length - 1
                                          ? 0
                                          : context.sp(8),
                                    ),
                                    child: _PendingAttachmentChip(
                                      attachment: attachment,
                                      appearance: appearance,
                                      resolveUrl: widget.api.resolveUrl,
                                      onTap: () => _openPendingMediaComposer(
                                        initialIndex: index,
                                      ),
                                      onRemove: () => _removePendingAttachment(
                                        attachment.localId,
                                      ),
                                      onRetry: attachment.isUploading
                                          ? null
                                          : () => _retryAttachment(attachment),
                                      trailingAction: ReorderableDragStartListener(
                                        index: index,
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: context.sp(8),
                                          ),
                                          child: Icon(
                                            Icons.drag_handle_rounded,
                                            size: context.sp(18),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_voiceRecording || _voiceUploading)
                      Container(
                        width: double.infinity,
                        margin: EdgeInsets.only(bottom: context.sp(8)),
                        padding: EdgeInsets.symmetric(
                          horizontal: context.sp(12),
                          vertical: context.sp(10),
                        ),
                        decoration: BoxDecoration(
                          color: appearance.surfaceRaisedColor,
                          borderRadius: BorderRadius.circular(context.sp(16)),
                          border: Border.all(color: appearance.outlineColor),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: context.sp(36),
                              height: context.sp(36),
                              decoration: BoxDecoration(
                                color: appearance.accentColor.withValues(
                                  alpha: 0.16,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: _voiceUploading
                                  ? Padding(
                                      padding: EdgeInsets.all(context.sp(8)),
                                      child: const CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      Icons.mic_rounded,
                                      color: appearance.accentColor,
                                    ),
                            ),
                            SizedBox(width: context.sp(12)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _voiceUploading
                                        ? 'Uploading voice message'
                                        : 'Recording voice message',
                                    style: TextStyle(
                                      fontSize: context.sp(13),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  SizedBox(height: context.sp(2)),
                                  Text(
                                    _voiceUploading
                                        ? 'Please wait until upload finishes'
                                        : _formatClockDuration(
                                            _voiceRecordingDuration,
                                          ),
                                    style: TextStyle(
                                      fontSize: context.sp(12),
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_voiceRecording)
                              IconButton(
                                tooltip: 'Cancel recording',
                                onPressed: _cancelVoiceRecording,
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                          ],
                        ),
                      ),
                    if (_messageController.text.trim().isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: context.sp(6)),
                        child: Text(
                          'Draft is saved automatically',
                          style: TextStyle(
                            fontSize: context.sp(11),
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        IconButton.filledTonal(
                          tooltip: 'Attach files',
                          onPressed:
                              _editingMessageId == null &&
                                  !_voiceRecording &&
                                  !_voiceUploading
                              ? _showAttachOptions
                              : null,
                          icon: const Icon(Icons.attach_file_rounded),
                        ),
                        SizedBox(width: context.sp(8)),
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            focusNode: _composerFocusNode,
                            minLines: 1,
                            maxLines: 5,
                            enabled: !_voiceRecording && !_voiceUploading,
                            decoration: InputDecoration(
                              hintText: _editingMessageId != null
                                  ? 'Edit message'
                                  : 'Message',
                            ),
                            onChanged: _onComposerChanged,
                          ),
                        ),
                        SizedBox(width: context.sp(8)),
                        IconButton.filledTonal(
                          tooltip: _voiceRecording
                              ? 'Stop and send voice message'
                              : 'Record voice message',
                          onPressed: _voiceUploading
                              ? null
                              : _voiceRecording
                              ? _finishVoiceRecording
                              : _canRecordVoice
                              ? _startVoiceRecording
                              : null,
                          icon: _voiceUploading
                              ? SizedBox(
                                  width: context.sp(16),
                                  height: context.sp(16),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _voiceRecording
                                      ? Icons.stop_rounded
                                      : Icons.mic_none_rounded,
                                ),
                        ),
                        SizedBox(width: context.sp(8)),
                        IconButton.filledTonal(
                          tooltip: widget.chat.type == 'private'
                              ? 'Schedule or send when online'
                              : 'Schedule message',
                          onPressed: _editingMessageId == null && _canSend
                              ? _showScheduleOptions
                              : null,
                          icon: const Icon(Icons.schedule_send_rounded),
                        ),
                        SizedBox(width: context.sp(8)),
                        FilledButton(
                          onPressed: _canSend ? _sendMessage : null,
                          onLongPress: _editingMessageId == null && _canSend
                              ? _showQuickSendOptions
                              : null,
                          child: vm.sending
                              ? SizedBox(
                                  width: context.sp(16),
                                  height: context.sp(16),
                                  child: const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_rounded),
                        ),
                      ],
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
}

class _PendingAttachmentChip extends StatelessWidget {
  final _PendingComposerAttachment attachment;
  final AppAppearanceData appearance;
  final String Function(String pathOrUrl) resolveUrl;
  final VoidCallback onRemove;
  final VoidCallback? onRetry;
  final VoidCallback? onTap;
  final Widget? trailingAction;

  const _PendingAttachmentChip({
    required this.attachment,
    required this.appearance,
    required this.resolveUrl,
    required this.onRemove,
    required this.onRetry,
    this.onTap,
    this.trailingAction,
  });

  @override
  Widget build(BuildContext context) {
    final uploaded = attachment.uploadedAttachment;
    final previewUrl = uploaded == null ? null : resolveUrl(uploaded.url);
    final thumbnailUrl = uploaded?.thumbnailUrl == null
        ? null
        : resolveUrl(uploaded!.thumbnailUrl!);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.sp(16)),
        child: Container(
          width: context.sp(140),
          padding: EdgeInsets.all(context.sp(8)),
          decoration: BoxDecoration(
            color: appearance.surfaceRaisedColor,
            borderRadius: BorderRadius.circular(context.sp(16)),
            border: Border.all(
              color: attachment.errorMessage != null
                  ? Theme.of(context).colorScheme.error
                  : appearance.outlineColor,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.sp(12)),
              child: Container(
                width: double.infinity,
                color: Colors.black.withValues(alpha: 0.08),
                child: _PendingAttachmentPreview(
                  attachment: attachment,
                  previewUrl: previewUrl,
                  thumbnailUrl: thumbnailUrl,
                ),
              ),
            ),
          ),
          SizedBox(height: context.sp(8)),
          Row(
            children: [
              Expanded(
                child: Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.sp(12),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (attachment.sendAsFile)
                Container(
                  margin: EdgeInsets.only(left: context.sp(6)),
                  padding: EdgeInsets.symmetric(
                    horizontal: context.sp(6),
                    vertical: context.sp(2),
                  ),
                  decoration: BoxDecoration(
                    color: appearance.accentColorMuted.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(context.sp(999)),
                  ),
                  child: Text(
                    'FILE',
                    style: TextStyle(
                      fontSize: context.sp(9),
                      fontWeight: FontWeight.w700,
                      color: appearance.accentColor,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: context.sp(2)),
          Text(
            attachment.errorMessage ??
                (attachment.isUploading
                    ? (attachment.sendAsFile
                        ? 'Uploading as file...'
                        : 'Uploading compressed media...')
                    : !attachment.isReadyForSend
                    ? (attachment.sendAsFile
                        ? 'Applying send as file...'
                        : 'Preparing compressed media...')
                    : uploaded != null
                    ? _formatBytes(uploaded.sizeBytes)
                    : _formatBytes(attachment.sizeBytes)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.sp(10),
              color: attachment.errorMessage != null
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: context.sp(4)),
          Row(
            children: [
              if (attachment.errorMessage != null && onRetry != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Retry upload',
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                )
              else if (attachment.isUploading)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.sp(8)),
                  child: SizedBox(
                    width: context.sp(16),
                    height: context.sp(16),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.sp(8)),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: context.sp(18),
                    color: appearance.accentColor,
                  ),
                ),
              const Spacer(),
              if (trailingAction != null) trailingAction!,
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove',
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ],
      ),
        ),
      ),
    );
  }
}

class _PendingComposerEditorResult {
  final List<_PendingComposerAttachment> attachments;
  final String caption;
  final _PendingComposerAction action;

  const _PendingComposerEditorResult({
    required this.attachments,
    required this.caption,
    this.action = _PendingComposerAction.apply,
  });
}

class _PendingComposerEditorPage extends StatefulWidget {
  final List<_PendingComposerAttachment> attachments;
  final int initialIndex;
  final String Function(String pathOrUrl) resolveUrl;
  final String initialCaption;
  final String chatTitle;
  final bool allowSendWhenOnline;

  const _PendingComposerEditorPage({
    required this.attachments,
    required this.initialIndex,
    required this.resolveUrl,
    required this.initialCaption,
    required this.chatTitle,
    required this.allowSendWhenOnline,
  });

  @override
  State<_PendingComposerEditorPage> createState() =>
      _PendingComposerEditorPageState();
}

class _PendingComposerEditorPageState extends State<_PendingComposerEditorPage> {
  late final PageController _pageController;
  late final TextEditingController _captionController;
  late List<_PendingComposerAttachment> _attachments;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _attachments = [...widget.attachments];
    _currentIndex = widget.initialIndex.clamp(0, _attachments.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    _captionController = TextEditingController(text: widget.initialCaption);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _captionController.dispose();
    super.dispose();
  }

  bool get _canToggleSendMode =>
      _attachments.any((item) => item.canToggleSendMode);

  bool get _visualsSentAsFiles {
    final visual = _attachments.where((item) => item.canToggleSendMode).toList();
    if (visual.isEmpty) return false;
    return visual.every((item) => item.sendAsFile);
  }

  bool get _allReadyToSubmit {
    return _attachments.isNotEmpty &&
        _attachments.every((item) => item.isReadyForSend) &&
        !_attachments.any((item) => item.isUploading || item.errorMessage != null);
  }

  int get _photoCount => _attachments.where((item) => item.isImage && item.isVisualMediaForSend).length;

  int get _videoCount => _attachments.where((item) => item.isVideo && item.isVisualMediaForSend).length;

  int get _fileCount => _attachments.where((item) => item.sendAsFile || (!item.isImage && !item.isVideo)).length;

  String get _albumSummary {
    final parts = <String>[];
    if (_photoCount > 0) parts.add('$_photoCount photo${_photoCount == 1 ? '' : 's'}');
    if (_videoCount > 0) parts.add('$_videoCount video${_videoCount == 1 ? '' : 's'}');
    if (_fileCount > 0 && (_photoCount == 0 || _videoCount == 0 || _visualsSentAsFiles)) {
      parts.add('$_fileCount file${_fileCount == 1 ? '' : 's'}');
    }
    if (parts.isEmpty) {
      parts.add('${_attachments.length} item${_attachments.length == 1 ? '' : 's'}');
    }
    return parts.join(' • ');
  }

  String _statusFor(_PendingComposerAttachment attachment) {
    if (attachment.errorMessage != null && !attachment.isReadyForSend) {
      return attachment.errorMessage!;
    }
    if (attachment.isUploading) {
      return attachment.sendAsFile
          ? 'Uploading as file...'
          : 'Uploading compressed media...';
    }
    if (!attachment.isReadyForSend) {
      return attachment.sendAsFile
          ? 'Apply send as file and wait for upload'
          : 'Preparing media preview...';
    }
    final uploaded = attachment.uploadedAttachment;
    if (uploaded != null) {
      return attachment.sendAsFile
          ? 'Ready to send as file • ${_formatBytes(uploaded.sizeBytes)}'
          : 'Ready to send • ${_formatBytes(uploaded.sizeBytes)}';
    }
    return _formatBytes(attachment.sizeBytes);
  }

  void _finish([_PendingComposerAction action = _PendingComposerAction.apply]) {
    Navigator.of(context).pop(
      _PendingComposerEditorResult(
        attachments: _attachments,
        caption: _captionController.text.trim(),
        action: action,
      ),
    );
  }

  void _toggleSendMode() {
    if (!_canToggleSendMode) return;
    final nextValue = !_visualsSentAsFiles;
    setState(() {
      _attachments = _attachments
          .map(
            (item) => item.canToggleSendMode
                ? item.copyWith(sendAsFile: nextValue)
                : item,
          )
          .toList();
    });
  }

  void _removeCurrent() {
    if (_attachments.isEmpty) return;
    setState(() {
      _attachments.removeAt(_currentIndex);
      if (_attachments.isEmpty) {
        _currentIndex = 0;
      } else if (_currentIndex >= _attachments.length) {
        _currentIndex = _attachments.length - 1;
      }
    });
    if (_attachments.isEmpty) {
      _finish();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pageController.jumpToPage(_currentIndex);
    });
  }

  void _moveCurrent(int delta) {
    final next = _currentIndex + delta;
    if (next < 0 || next >= _attachments.length) return;
    setState(() {
      final item = _attachments.removeAt(_currentIndex);
      _attachments.insert(next, item);
      _currentIndex = next;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pageController.jumpToPage(_currentIndex);
    });
  }

  Future<void> _showSendOptions() async {
    if (!_allReadyToSubmit || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('Send silently'),
                subtitle: const Text('Deliver without a sound notification'),
                onTap: () {
                  Navigator.of(context).pop();
                  Future.microtask(() => _finish(_PendingComposerAction.sendSilently));
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule_send_rounded),
                title: const Text('Schedule message'),
                subtitle: const Text('Choose a delivery time'),
                onTap: () {
                  Navigator.of(context).pop();
                  Future.microtask(() => _finish(_PendingComposerAction.scheduleAt));
                },
              ),
              if (widget.allowSendWhenOnline)
                ListTile(
                  leading: const Icon(Icons.bolt_rounded),
                  title: const Text('Send when online'),
                  subtitle: const Text('Deliver as soon as the recipient appears online'),
                  onTap: () {
                    Navigator.of(context).pop();
                    Future.microtask(() => _finish(_PendingComposerAction.sendWhenOnline));
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attachment = _attachments[_currentIndex];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Album preview'),
        actions: [
          IconButton(
            tooltip: 'Remove from album',
            onPressed: _removeCurrent,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          IconButton(
            tooltip: 'Done',
            onPressed: _finish,
            icon: const Icon(Icons.check_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _attachments.length,
                  onPageChanged: (index) => setState(() => _currentIndex = index),
                  itemBuilder: (context, index) {
                    final item = _attachments[index];
                    final uploaded = item.uploadedAttachment;
                    final previewUrl = uploaded == null
                        ? null
                        : widget.resolveUrl(uploaded.url);
                    final thumbnailUrl = uploaded?.thumbnailUrl == null ||
                            uploaded!.thumbnailUrl!.trim().isEmpty
                        ? null
                        : widget.resolveUrl(uploaded.thumbnailUrl!);
                    return Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: ColoredBox(
                            color: Colors.white.withValues(alpha: 0.06),
                            child: _PendingAttachmentPreview(
                              attachment: item,
                              previewUrl: previewUrl,
                              thumbnailUrl: thumbnailUrl,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  attachment.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'To ${widget.chatTitle} • ${_albumSummary}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_attachments.length > 1) ...[
                            IconButton(
                              tooltip: 'Move left',
                              onPressed: _currentIndex == 0
                                  ? null
                                  : () => _moveCurrent(-1),
                              icon: const Icon(Icons.arrow_back_rounded),
                              color: Colors.white,
                            ),
                            IconButton(
                              tooltip: 'Move right',
                              onPressed: _currentIndex >= _attachments.length - 1
                                  ? null
                                  : () => _moveCurrent(1),
                              icon: const Icon(Icons.arrow_forward_rounded),
                              color: Colors.white,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _statusFor(attachment),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _captionController,
                        minLines: 2,
                        maxLines: 4,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Caption',
                          labelStyle: const TextStyle(color: Colors.white70),
                          hintText: 'Add a caption for the whole album',
                          hintStyle: const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: BorderSide(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: BorderSide(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: const BorderSide(color: Colors.white70),
                          ),
                          prefixIcon: const Icon(
                            Icons.notes_rounded,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 86,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _attachments.length,
                          separatorBuilder: (context, index) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final item = _attachments[index];
                            final uploaded = item.uploadedAttachment;
                            final previewUrl = uploaded == null
                                ? null
                                : widget.resolveUrl(uploaded.url);
                            final thumbnailUrl = uploaded?.thumbnailUrl == null ||
                                    uploaded!.thumbnailUrl!.trim().isEmpty
                                ? null
                                : widget.resolveUrl(uploaded.thumbnailUrl!);
                            return GestureDetector(
                              onTap: () {
                                setState(() => _currentIndex = index);
                                _pageController.animateToPage(
                                  index,
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOut,
                                );
                              },
                              child: SizedBox(
                                width: 76,
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(
                                            color: index == _currentIndex
                                                ? Colors.white
                                                : Colors.white.withValues(alpha: 0.18),
                                            width: index == _currentIndex ? 2 : 1,
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(15),
                                          child: ColoredBox(
                                            color: Colors.white.withValues(alpha: 0.04),
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                _PendingAttachmentPreview(
                                                  attachment: item,
                                                  previewUrl: previewUrl,
                                                  thumbnailUrl: thumbnailUrl,
                                                ),
                                                if (item.isVideo && !item.sendAsFile)
                                                  Positioned(
                                                    right: 6,
                                                    bottom: 6,
                                                    child: DecoratedBox(
                                                      decoration: BoxDecoration(
                                                        color: Colors.black.withValues(alpha: 0.52),
                                                        borderRadius: BorderRadius.circular(999),
                                                      ),
                                                      child: const Padding(
                                                        padding: EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 2,
                                                        ),
                                                        child: Icon(
                                                          Icons.videocam_rounded,
                                                          size: 14,
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                if (item.sendAsFile)
                                                  Positioned(
                                                    left: 6,
                                                    top: 6,
                                                    child: DecoratedBox(
                                                      decoration: BoxDecoration(
                                                        color: Colors.black.withValues(alpha: 0.56),
                                                        borderRadius: BorderRadius.circular(999),
                                                      ),
                                                      child: const Padding(
                                                        padding: EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 3,
                                                        ),
                                                        child: Text(
                                                          'FILE',
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 10,
                                                            fontWeight: FontWeight.w700,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${index + 1}',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: index == _currentIndex
                                            ? Colors.white
                                            : Colors.white54,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (_canToggleSendMode)
                            FilterChip(
                              selected: _visualsSentAsFiles,
                              onSelected: (_) => _toggleSendMode(),
                              avatar: Icon(
                                _visualsSentAsFiles
                                    ? Icons.file_present_rounded
                                    : Icons.auto_awesome_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              backgroundColor: Colors.white.withValues(alpha: 0.06),
                              selectedColor: Colors.white.withValues(alpha: 0.14),
                              checkmarkColor: Colors.white,
                              label: Text(
                                _visualsSentAsFiles ? 'Send as files' : 'Send compressed',
                                style: const TextStyle(color: Colors.white),
                              ),
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                          const Spacer(),
                          OutlinedButton.icon(
                            onPressed: _allReadyToSubmit ? _showSendOptions : null,
                            icon: const Icon(Icons.more_horiz_rounded),
                            label: const Text('More'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.22),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: _allReadyToSubmit
                                ? () => _finish(_PendingComposerAction.sendNow)
                                : null,
                            icon: const Icon(Icons.send_rounded),
                            label: const Text('Send'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingAttachmentPreview extends StatelessWidget {
  final _PendingComposerAttachment attachment;
  final String? previewUrl;
  final String? thumbnailUrl;

  const _PendingAttachmentPreview({
    required this.attachment,
    required this.previewUrl,
    required this.thumbnailUrl,
  });

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => _PendingAttachmentPlaceholder(attachment: attachment);

    if (attachment.isImage) {
      if (!kIsWeb && attachment.filePath != null && attachment.filePath!.isNotEmpty) {
        return Image.file(
          File(attachment.filePath!),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => placeholder(),
        );
      }
      if (attachment.bytes != null) {
        return Image.memory(
          attachment.bytes!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => placeholder(),
        );
      }
    }

    if (attachment.isVideo && thumbnailUrl != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            thumbnailUrl!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => placeholder(),
          ),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.play_arrow_rounded, color: Colors.white),
              ),
            ),
          ),
        ],
      );
    }

    if (attachment.uploadedAttachment?.isImage == true && previewUrl != null) {
      return Image.network(
        previewUrl!,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => placeholder(),
      );
    }

    return placeholder();
  }
}

class _PendingAttachmentPlaceholder extends StatelessWidget {
  final _PendingComposerAttachment attachment;

  const _PendingAttachmentPlaceholder({required this.attachment});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        attachment.isImage
            ? Icons.image_outlined
            : attachment.isVideo
            ? Icons.smart_display_outlined
            : attachment.isAudio
            ? Icons.mic_rounded
            : Icons.attach_file_rounded,
        size: context.sp(26),
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _QuickReactionButton extends StatelessWidget {
  final String emoji;
  final bool active;
  final VoidCallback onTap;

  const _QuickReactionButton({
    required this.emoji,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: active
          ? colorScheme.primary.withValues(alpha: 0.18)
          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(context.sp(14)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.sp(14)),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.sp(10),
            vertical: context.sp(10),
          ),
          child: Center(
            child: Text(emoji, style: TextStyle(fontSize: context.sp(22))),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageItem message;
  final MessageItem? repliedMessage;
  final bool mine;
  final AppAppearanceData appearance;
  final bool highlighted;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onReplyPreviewTap;
  final String Function(String pathOrUrl) attachmentUrlBuilder;
  final Future<void> Function(MessageAttachmentItem attachment)?
  onAttachmentTap;
  final Future<void> Function(
    List<MessageAttachmentItem> attachments,
    int initialIndex,
  )?
  onMediaAlbumTap;
  final double? Function(int attachmentId)? attachmentDownloadProgressLookup;
  final Future<void> Function(String emoji, bool reactedByMe)? onReactionTap;

  const _MessageBubble({
    super.key,
    required this.message,
    required this.repliedMessage,
    required this.mine,
    required this.appearance,
    this.highlighted = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.onReplyPreviewTap,
    required this.attachmentUrlBuilder,
    this.onAttachmentTap,
    this.onMediaAlbumTap,
    this.attachmentDownloadProgressLookup,
    this.onReactionTap,
  });

  @override
  Widget build(BuildContext context) {
    final bubbleColor = mine
        ? appearance.outgoingBubbleColor
        : appearance.incomingBubbleColor;
    final borderColor = mine
        ? appearance.outgoingBubbleBorderColor
        : appearance.incomingBubbleBorderColor;
    final alignment = mine ? Alignment.centerRight : Alignment.centerLeft;
    final textSize = context.sp(15) * appearance.messageTextScale;
    final metaSize =
        context.sp(11) * appearance.messageTextScale.clamp(0.95, 1.15);
    final radius = BorderRadius.only(
      topLeft: Radius.circular(context.sp(16)),
      topRight: Radius.circular(context.sp(16)),
      bottomLeft: Radius.circular(mine ? context.sp(16) : context.sp(4)),
      bottomRight: Radius.circular(mine ? context.sp(4) : context.sp(16)),
    );
    final replyPreview = repliedMessage?.content.trim().isNotEmpty == true
        ? repliedMessage!.content
        : message.replyToMessageId != null
        ? 'Reply to message'
        : null;
    final attachmentColor = Theme.of(context).colorScheme.onSurfaceVariant;

    return Align(
      alignment: alignment,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: radius,
          child: Container(
            margin: EdgeInsets.symmetric(vertical: context.sp(4)),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: context.sp(12),
              vertical: context.sp(8),
            ),
            decoration: BoxDecoration(
              color: selected
                  ? Color.alphaBlend(
                      appearance.accentColor.withValues(alpha: 0.18),
                      bubbleColor,
                    )
                  : highlighted
                  ? Color.alphaBlend(
                      appearance.accentColor.withValues(alpha: 0.12),
                      bubbleColor,
                    )
                  : bubbleColor,
              borderRadius: radius,
              border: Border.all(
                color: selected || highlighted ? appearance.accentColor : borderColor,
                width: selected || highlighted ? 1.5 : 1,
              ),
              boxShadow: highlighted
                  ? [
                      BoxShadow(
                        color: appearance.accentColor.withValues(alpha: 0.18),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if ((message.forwardedFromSenderName ?? '').trim().isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: EdgeInsets.only(bottom: context.sp(8)),
                    padding: EdgeInsets.symmetric(
                      horizontal: context.sp(10),
                      vertical: context.sp(8),
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(context.sp(12)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.forward_rounded,
                          size: context.sp(16),
                          color: appearance.accentColor,
                        ),
                        SizedBox(width: context.sp(8)),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Forwarded from ${message.forwardedFromSenderName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: context.sp(12) * appearance.messageTextScale,
                                  fontWeight: FontWeight.w700,
                                  color: appearance.accentColor,
                                ),
                              ),
                              if ((message.forwardedFromChatTitle ?? '').trim().isNotEmpty)
                                Padding(
                                  padding: EdgeInsets.only(top: context.sp(2)),
                                  child: Text(
                                    message.forwardedFromChatTitle!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: context.sp(11) * appearance.messageTextScale,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (replyPreview != null)
                  GestureDetector(
                    onTap: onReplyPreviewTap,
                    child: Container(
                    width: double.infinity,
                    margin: EdgeInsets.only(bottom: context.sp(8)),
                    padding: EdgeInsets.symmetric(
                      horizontal: context.sp(10),
                      vertical: context.sp(8),
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(context.sp(12)),
                      border: Border(
                        left: BorderSide(
                          color: appearance.accentColor,
                          width: context.sp(3),
                        ),
                      ),
                    ),
                    child: Text(
                      replyPreview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.sp(12) * appearance.messageTextScale,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                if (message.content.trim().isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      message.content,
                      style: TextStyle(fontSize: textSize),
                    ),
                  ),
                if (message.attachments.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: message.content.trim().isEmpty ? 0 : context.sp(8),
                    ),
                    child: _MessageAttachmentsBlock(
                      attachments: message.attachments,
                      appearance: appearance,
                      attachmentUrlBuilder: attachmentUrlBuilder,
                      onAttachmentTap: onAttachmentTap,
                      onMediaAlbumTap: onMediaAlbumTap,
                      attachmentDownloadProgressLookup:
                          attachmentDownloadProgressLookup,
                    ),
                  ),
                if (message.reactions.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: context.sp(4)),
                    child: Wrap(
                      spacing: context.sp(6),
                      runSpacing: context.sp(6),
                      children: message.reactions
                          .map(
                            (reaction) => InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: onReactionTap == null
                                  ? null
                                  : () => onReactionTap!(
                                      reaction.emoji,
                                      reaction.reactedByMe,
                                    ),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: context.sp(8),
                                  vertical: context.sp(4),
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: reaction.reactedByMe
                                        ? appearance.accentColor
                                        : borderColor,
                                  ),
                                ),
                                child: Text(
                                  '${reaction.emoji} ${reaction.count}',
                                  style: TextStyle(
                                    fontSize:
                                        context.sp(11) *
                                        appearance.messageTextScale,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                SizedBox(height: context.sp(4)),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.isPinned)
                      Padding(
                        padding: EdgeInsets.only(right: context.sp(4)),
                        child: Icon(
                          Icons.push_pin_rounded,
                          size: context.sp(14),
                          color: appearance.accentColor,
                        ),
                      ),
                    if (message.editedAt != null)
                      Padding(
                        padding: EdgeInsets.only(right: context.sp(6)),
                        child: Text(
                          'edited',
                          style: TextStyle(
                            fontSize: metaSize,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Text(
                      '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')} ${mine ? _statusMark(message.status) : ''}',
                      style: TextStyle(
                        fontSize: metaSize,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _statusMark(String status) {
    switch (status) {
      case 'read':
        return '\u2713\u2713';
      case 'delivered':
        return '\u2713';
      case 'pending':
      case 'sending':
        return '\u23f3';
      case 'failed':
        return '!';
      default:
        return '';
    }
  }
}

class _AudioAttachmentTile extends ConsumerWidget {
  final MessageAttachmentItem attachment;
  final String url;
  final AppAppearanceData appearance;

  const _AudioAttachmentTile({
    required this.attachment,
    required this.url,
    required this.appearance,
  });

  Future<void> _togglePlayback(WidgetRef ref) async {
    final playback = ref.read(chatAudioPlaybackProvider);
    if (playback.isCurrentAttachment(attachment.id)) {
      await playback.togglePlayback();
      return;
    }
    await playback.playSingle(
      ChatAudioQueueItem(
        attachment: attachment,
        audioUrl: url,
        title: attachment.displayLabel,
        subtitle: attachment.isVoice ? 'Voice message' : 'Audio attachment',
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(chatAudioPlaybackProvider);
    final isCurrent = playback.isCurrentAttachment(attachment.id);
    final active = playback.isPlayingAttachment(attachment.id);
    final position = isCurrent ? playback.position : Duration.zero;
    final duration = isCurrent
        ? playback.effectiveDuration
        : attachment.durationSeconds == null
        ? Duration.zero
        : Duration(seconds: attachment.durationSeconds!);
    final total = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final progress = isCurrent
        ? (position.inMilliseconds / total).clamp(0.0, 1.0)
        : 0.0;

    return Row(
      children: [
        IconButton.filledTonal(
          tooltip: active ? 'Pause' : 'Play',
          onPressed: () async {
            await _togglePlayback(ref);
          },
          icon: Icon(active ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        SizedBox(width: context.sp(8)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                attachment.displayLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.sp(13) * appearance.messageTextScale,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: context.sp(4)),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: context.sp(5),
                  backgroundColor: Colors.black.withValues(alpha: 0.08),
                ),
              ),
              SizedBox(height: context.sp(4)),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_formatClockDuration(position)} / ${_formatClockDuration(duration)}',
                      style: TextStyle(
                        fontSize: context.sp(11) * appearance.messageTextScale,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (isCurrent)
                    Text(
                      playback.isPlaying
                          ? 'Playing'
                          : playback.isPaused
                          ? 'Paused'
                          : playback.isCompleted
                          ? 'Ended'
                          : 'Ready',
                      style: TextStyle(
                        fontSize: context.sp(11) * appearance.messageTextScale,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VideoAttachmentFallback extends StatelessWidget {
  final Color attachmentColor;
  final MessageAttachmentItem attachment;

  const _VideoAttachmentFallback({
    required this.attachmentColor,
    required this.attachment,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.08),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.smart_display_outlined,
            size: context.sp(32),
            color: attachmentColor,
          ),
          SizedBox(height: context.sp(8)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.sp(10)),
            child: Text(
              attachment.previewLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: attachmentColor,
                fontSize: context.sp(12),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageAttachmentsBlock extends StatelessWidget {
  final List<MessageAttachmentItem> attachments;
  final AppAppearanceData appearance;
  final String Function(String pathOrUrl) attachmentUrlBuilder;
  final Future<void> Function(MessageAttachmentItem attachment)? onAttachmentTap;
  final Future<void> Function(
    List<MessageAttachmentItem> attachments,
    int initialIndex,
  )?
  onMediaAlbumTap;
  final double? Function(int attachmentId)? attachmentDownloadProgressLookup;

  const _MessageAttachmentsBlock({
    required this.attachments,
    required this.appearance,
    required this.attachmentUrlBuilder,
    this.onAttachmentTap,
    this.onMediaAlbumTap,
    this.attachmentDownloadProgressLookup,
  });

  @override
  Widget build(BuildContext context) {
    if (_isMediaAlbumCandidate(attachments)) {
      return _MessageMediaAlbumGrid(
        attachments: attachments,
        attachmentUrlBuilder: attachmentUrlBuilder,
        onOpenItem: onMediaAlbumTap,
      );
    }

    final attachmentColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      children: attachments.map((attachment) {
        final downloadProgress = attachmentDownloadProgressLookup?.call(
          attachment.id,
        );
        final child = attachment.isImage
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(context.sp(10)),
                    child: CachedNetworkImage(
                      imageUrl: attachmentUrlBuilder(attachment.url),
                      height: context.sp(140),
                      width: double.infinity,
                      fit: BoxFit.cover,
                      progressIndicatorBuilder: (context, url, progress) =>
                          Container(
                            height: context.sp(140),
                            color: Colors.black.withValues(alpha: 0.08),
                            alignment: Alignment.center,
                            child: CircularProgressIndicator(
                              value: progress.progress,
                            ),
                          ),
                      errorWidget: (context, url, error) => Container(
                        height: context.sp(140),
                        color: Colors.black.withValues(alpha: 0.08),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.broken_image_outlined,
                          size: context.sp(28),
                          color: attachmentColor,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: context.sp(8)),
                  Text(
                    attachment.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.sp(13) * appearance.messageTextScale,
                    ),
                  ),
                ],
              )
            : attachment.isVideo
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(context.sp(10)),
                    child: Stack(
                      children: [
                        SizedBox(
                          height: context.sp(140),
                          width: double.infinity,
                          child: attachment.thumbnailUrl != null &&
                                  attachment.thumbnailUrl!.trim().isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: attachmentUrlBuilder(
                                    attachment.thumbnailUrl!,
                                  ),
                                  fit: BoxFit.cover,
                                  errorWidget: (context, url, error) =>
                                      _VideoAttachmentFallback(
                                        attachmentColor: attachmentColor,
                                        attachment: attachment,
                                      ),
                                )
                              : _VideoAttachmentFallback(
                                  attachmentColor: attachmentColor,
                                  attachment: attachment,
                                ),
                        ),
                        Positioned.fill(
                          child: Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.42),
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: EdgeInsets.all(context.sp(10)),
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  size: context.sp(28),
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: context.sp(8)),
                  Text(
                    attachment.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.sp(13) * appearance.messageTextScale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(top: context.sp(2)),
                    child: Text(
                      attachment.durationSeconds != null
                          ? '${_formatClockDuration(Duration(seconds: attachment.durationSeconds!))} • ${_formatBytes(attachment.sizeBytes)}'
                          : _formatBytes(attachment.sizeBytes),
                      style: TextStyle(
                        fontSize: context.sp(11) * appearance.messageTextScale,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              )
            : attachment.isAudio
            ? _AudioAttachmentTile(
                attachment: attachment,
                url: attachmentUrlBuilder(attachment.url),
                appearance: appearance,
              )
            : Row(
                children: [
                  Icon(
                    Icons.attach_file_rounded,
                    size: context.sp(18),
                    color: attachmentColor,
                  ),
                  SizedBox(width: context.sp(8)),
                  Expanded(
                    child: Text(
                      attachment.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.sp(13) * appearance.messageTextScale,
                      ),
                    ),
                  ),
                ],
              );

        return Padding(
          padding: EdgeInsets.only(bottom: context.sp(6)),
          child: InkWell(
            borderRadius: BorderRadius.circular(context.sp(12)),
            onTap: onAttachmentTap == null ? null : () => onAttachmentTap!(attachment),
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    horizontal: context.sp(10),
                    vertical: context.sp(8),
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(context.sp(12)),
                  ),
                  child: child,
                ),
                if (downloadProgress != null)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(context.sp(12)),
                      ),
                      child: Center(
                        child: SizedBox(
                          width: context.sp(132),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              SizedBox(height: context.sp(10)),
                              Text(
                                downloadProgress <= 0
                                    ? 'Downloading...'
                                    : 'Downloading ${(downloadProgress * 100).round()}%',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: context.sp(12),
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _MessageMediaAlbumGrid extends StatelessWidget {
  final List<MessageAttachmentItem> attachments;
  final String Function(String pathOrUrl) attachmentUrlBuilder;
  final Future<void> Function(List<MessageAttachmentItem> attachments, int initialIndex)?
  onOpenItem;

  const _MessageMediaAlbumGrid({
    required this.attachments,
    required this.attachmentUrlBuilder,
    this.onOpenItem,
  });

  @override
  Widget build(BuildContext context) {
    final spacing = context.sp(4);
    final visible = attachments.take(4).toList();
    final extraCount = attachments.length - visible.length;
    final tiles = visible.asMap().entries.map((entry) {
      final index = entry.key;
      final attachment = entry.value;
      return _MessageMediaAlbumTile(
        attachment: attachment,
        previewUrl: attachmentUrlBuilder(
          attachment.isVideo &&
                  attachment.thumbnailUrl != null &&
                  attachment.thumbnailUrl!.trim().isNotEmpty
              ? attachment.thumbnailUrl!
              : attachment.url,
        ),
        overlayLabel: index == visible.length - 1 && extraCount > 0
            ? '+$extraCount'
            : null,
        onTap: onOpenItem == null ? null : () => onOpenItem!(attachments, index),
      );
    }).toList();

    Widget twoColumnGrid(List<Widget> gridTiles) {
      return GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: 1,
        children: gridTiles,
      );
    }

    if (tiles.length == 2) {
      return Row(
        children: [
          Expanded(child: AspectRatio(aspectRatio: 0.95, child: tiles[0])),
          SizedBox(width: spacing),
          Expanded(child: AspectRatio(aspectRatio: 0.95, child: tiles[1])),
        ],
      );
    }

    if (tiles.length == 3) {
      return SizedBox(
        height: context.sp(220),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: SizedBox.expand(child: tiles[0]),
            ),
            SizedBox(width: spacing),
            Expanded(
              flex: 4,
              child: Column(
                children: [
                  Expanded(child: tiles[1]),
                  SizedBox(height: spacing),
                  Expanded(child: tiles[2]),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (tiles.length >= 4) {
      return twoColumnGrid(
        tiles
            .map((tile) => AspectRatio(aspectRatio: 1, child: tile))
            .toList(),
      );
    }

    return AspectRatio(aspectRatio: 1.3, child: tiles.first);
  }
}

class _MessageMediaAlbumTile extends StatelessWidget {
  final MessageAttachmentItem attachment;
  final String previewUrl;
  final String? overlayLabel;
  final VoidCallback? onTap;

  const _MessageMediaAlbumTile({
    required this.attachment,
    required this.previewUrl,
    this.overlayLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.sp(12)),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(context.sp(12)),
            color: Colors.black.withValues(alpha: 0.08),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(context.sp(12)),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: previewUrl,
                  fit: BoxFit.cover,
                  progressIndicatorBuilder: (context, url, progress) => Center(
                    child: CircularProgressIndicator(value: progress.progress),
                  ),
                  errorWidget: (context, url, error) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.08),
                    ),
                    child: Icon(
                      attachment.isVideo
                          ? Icons.smart_display_outlined
                          : Icons.image_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (attachment.isVideo)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.22),
                      ),
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(context.sp(8)),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: context.sp(24),
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (overlayLabel != null)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.42),
                      ),
                      child: Center(
                        child: Text(
                          overlayLabel!,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: context.sp(24),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingComposerAttachment {
  final int localId;
  final String clientUploadId;
  final String name;
  final int sizeBytes;
  final bool isImage;
  final bool isAudio;
  final bool isVideo;
  final bool sendAsFile;
  final String? filePath;
  final Uint8List? bytes;
  final bool isUploading;
  final String? errorMessage;
  final MessageAttachmentItem? uploadedAttachment;

  const _PendingComposerAttachment({
    required this.localId,
    required this.clientUploadId,
    required this.name,
    required this.sizeBytes,
    required this.isImage,
    required this.isAudio,
    required this.isVideo,
    required this.sendAsFile,
    required this.filePath,
    required this.bytes,
    required this.isUploading,
    required this.errorMessage,
    required this.uploadedAttachment,
  });

  factory _PendingComposerAttachment.fromPlatformFile({
    required int localId,
    required String clientUploadId,
    required PlatformFile file,
  }) {
    final lowerName = file.name.toLowerCase();
    return _PendingComposerAttachment(
      localId: localId,
      clientUploadId: clientUploadId,
      name: file.name,
      sizeBytes: file.size,
      isImage:
          lowerName.endsWith('.png') ||
          lowerName.endsWith('.jpg') ||
          lowerName.endsWith('.jpeg') ||
          lowerName.endsWith('.gif') ||
          lowerName.endsWith('.webp'),
      isAudio:
          lowerName.endsWith('.m4a') ||
          lowerName.endsWith('.aac') ||
          lowerName.endsWith('.mp3') ||
          lowerName.endsWith('.wav') ||
          lowerName.endsWith('.ogg') ||
          lowerName.endsWith('.oga') ||
          lowerName.endsWith('.opus'),
      isVideo:
          lowerName.endsWith('.mp4') ||
          lowerName.endsWith('.mov') ||
          lowerName.endsWith('.mkv') ||
          lowerName.endsWith('.webm') ||
          lowerName.endsWith('.avi') ||
          lowerName.endsWith('.m4v'),
      sendAsFile: false,
      filePath: file.path,
      bytes: file.bytes,
      isUploading: true,
      errorMessage: null,
      uploadedAttachment: null,
    );
  }

  factory _PendingComposerAttachment.fromCacheJson(Map<String, dynamic> json) {
    return _PendingComposerAttachment(
      localId: (json['local_id'] ?? 0) as int,
      clientUploadId: (json['client_upload_id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      sizeBytes: (json['size_bytes'] ?? 0) as int,
      isImage: (json['is_image'] ?? false) == true,
      isAudio: (json['is_audio'] ?? false) == true,
      isVideo: (json['is_video'] ?? false) == true,
      sendAsFile: (json['send_as_file'] ?? false) == true,
      filePath: json['file_path']?.toString(),
      bytes: null,
      isUploading: false,
      errorMessage: json['error_message']?.toString(),
      uploadedAttachment: json['uploaded_attachment'] is Map
          ? MessageAttachmentItem.fromJson(
              (json['uploaded_attachment'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }

  _PendingComposerAttachment copyWith({
    int? localId,
    String? clientUploadId,
    String? name,
    int? sizeBytes,
    bool? isImage,
    bool? isAudio,
    bool? isVideo,
    bool? sendAsFile,
    Object? filePath = _pendingAttachmentSentinel,
    Object? bytes = _pendingAttachmentSentinel,
    bool? isUploading,
    Object? errorMessage = _pendingAttachmentSentinel,
    Object? uploadedAttachment = _pendingAttachmentSentinel,
  }) {
    return _PendingComposerAttachment(
      localId: localId ?? this.localId,
      clientUploadId: clientUploadId ?? this.clientUploadId,
      name: name ?? this.name,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      isImage: isImage ?? this.isImage,
      isAudio: isAudio ?? this.isAudio,
      isVideo: isVideo ?? this.isVideo,
      sendAsFile: sendAsFile ?? this.sendAsFile,
      filePath: filePath == _pendingAttachmentSentinel
          ? this.filePath
          : filePath as String?,
      bytes: bytes == _pendingAttachmentSentinel
          ? this.bytes
          : bytes as Uint8List?,
      isUploading: isUploading ?? this.isUploading,
      errorMessage: errorMessage == _pendingAttachmentSentinel
          ? this.errorMessage
          : errorMessage as String?,
      uploadedAttachment: uploadedAttachment == _pendingAttachmentSentinel
          ? this.uploadedAttachment
          : uploadedAttachment as MessageAttachmentItem?,
    );
  }

  Map<String, dynamic> toCacheJson() {
    return {
      'local_id': localId,
      'client_upload_id': clientUploadId,
      'name': name,
      'size_bytes': sizeBytes,
      'is_image': isImage,
      'is_audio': isAudio,
      'is_video': isVideo,
      'send_as_file': sendAsFile,
      'file_path': filePath,
      'error_message': errorMessage,
      'uploaded_attachment': uploadedAttachment?.toJson(),
    };
  }

  bool get canPersistInQueue =>
      uploadedAttachment != null ||
      bytes != null ||
      (filePath != null && filePath!.trim().isNotEmpty);

  bool get canRestoreIntoComposer =>
      uploadedAttachment != null ||
      bytes != null ||
      (filePath != null && filePath!.trim().isNotEmpty);

  bool get canToggleSendMode => isImage || isVideo;

  bool get canUploadFromLocal =>
      bytes != null || (filePath != null && filePath!.trim().isNotEmpty);

  bool get isVisualMediaForSend => !sendAsFile && (isImage || isVideo);

  bool get uploadMatchesDesiredMode {
    final uploaded = uploadedAttachment;
    if (uploaded == null) return false;
    if (sendAsFile && canToggleSendMode) {
      return uploaded.mediaKind == 'file';
    }
    if (isVideo) return uploaded.isVideo;
    if (isImage) return uploaded.isImage;
    if (isAudio) return uploaded.isAudio;
    return true;
  }

  bool get isReadyForSend => uploadedAttachment != null && uploadMatchesDesiredMode;

  bool get shouldResumeUpload =>
      !isReadyForSend && !isUploading && canUploadFromLocal;

  String? get desiredKindHint {
    if (sendAsFile && canToggleSendMode) return 'file';
    if (isVideo) return 'video';
    if (isImage) return 'image';
    if (isAudio) return 'audio';
    return null;
  }
}

const Object _pendingAttachmentSentinel = Object();

String _formatClockDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}

class _SharedMediaBrowserPage extends StatefulWidget {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final ChatItem chat;

  const _SharedMediaBrowserPage({
    required this.api,
    required this.getTokens,
    required this.chat,
  });

  @override
  State<_SharedMediaBrowserPage> createState() => _SharedMediaBrowserPageState();
}

class _SharedMediaBrowserPageState extends State<_SharedMediaBrowserPage> {
  static const List<String> _filters = <String>[
    'all',
    'image',
    'video',
    'audio',
    'file',
  ];

  bool _loading = true;
  String? _error;
  String _activeFilter = 'all';
  List<SharedMediaItem> _items = const <SharedMediaItem>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final tokens = widget.getTokens();
    if (tokens == null) {
      setState(() {
        _loading = false;
        _error = 'Session expired';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.api.listSharedMedia(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: widget.chat.id,
        kind: _activeFilter == 'all' ? null : _activeFilter,
        limit: 250,
      );
      if (!mounted) return;
      setState(() {
        _items = rows;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _openItem(SharedMediaItem item) async {
    final attachment = item.attachment;
    if (attachment.isImage) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ChatPhotoViewerPage(
            attachment: attachment,
            imageUrl: widget.api.resolveUrl(attachment.url),
          ),
        ),
      );
      return;
    }
    if (attachment.isVideo) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ChatVideoViewerPage(
            attachment: attachment,
            videoUrl: widget.api.resolveUrl(attachment.url),
          ),
        ),
      );
      return;
    }
    if (attachment.isAudio) {
      final audioItems = _items.where((row) => row.attachment.isAudio).toList();
      final queue = audioItems
          .map(
            (row) => ChatAudioQueueItem(
              attachment: row.attachment,
              audioUrl: widget.api.resolveUrl(row.attachment.url),
              title: row.attachment.displayLabel,
              subtitle: row.content.trim().isEmpty
                  ? _formatSharedMediaMoment(row.messageCreatedAt)
                  : row.content.trim(),
            ),
          )
          .toList();
      final initialIndex = audioItems.indexWhere(
        (row) => row.attachment.id == attachment.id,
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ChatAudioPlayerPage(
            queue: queue,
            initialIndex: initialIndex < 0 ? 0 : initialIndex,
          ),
        ),
      );
      return;
    }
    final uri = Uri.tryParse(widget.api.resolveUrl(attachment.url));
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final appearance = Theme.of(context).colorScheme;
    final mediaCount = _items.length;
    final showGrid = _activeFilter == 'image' || _activeFilter == 'video';

    return Scaffold(
      appBar: AppBar(
        title: Text('Shared media • ${widget.chat.title}'),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: _filters.map((filter) {
                final selected = filter == _activeFilter;
                final label = switch (filter) {
                  'image' => 'Photos',
                  'video' => 'Videos',
                  'audio' => 'Music',
                  'file' => 'Files',
                  _ => 'All',
                };
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (_) {
                      if (_activeFilter == filter) return;
                      setState(() => _activeFilter = filter);
                      unawaited(_load());
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text(
                  _loading ? 'Loading…' : '$mediaCount item(s)',
                  style: TextStyle(
                    color: appearance.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline_rounded, size: 36),
                          const SizedBox(height: 12),
                          Text(_error!, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  )
                : _items.isEmpty
                ? const Center(child: Text('No shared media yet'))
                : showGrid
                ? GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      final attachment = item.attachment;
                      final previewUrl = attachment.thumbnailUrl == null
                          ? widget.api.resolveUrl(attachment.url)
                          : widget.api.resolveUrl(attachment.thumbnailUrl!);
                      return InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => unawaited(_openItem(item)),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: appearance.surfaceContainerHighest,
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: CachedNetworkImage(
                                    imageUrl: previewUrl,
                                    fit: BoxFit.cover,
                                    errorWidget: (context, url, error) => Center(
                                      child: Icon(
                                        attachment.isVideo
                                            ? Icons.videocam_rounded
                                            : Icons.image_rounded,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (attachment.isVideo)
                                Positioned.fill(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.24),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.play_circle_fill_rounded,
                                        color: Colors.white,
                                        size: 36,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      final attachment = item.attachment;
                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        tileColor: appearance.surfaceContainerLow,
                        leading: CircleAvatar(
                          child: Icon(
                            attachment.isAudio
                                ? (attachment.isVoice
                                      ? Icons.mic_rounded
                                      : Icons.graphic_eq_rounded)
                                : Icons.insert_drive_file_rounded,
                          ),
                        ),
                        title: Text(
                          attachment.displayLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${attachment.previewLabel} • ${_formatBytes(attachment.sizeBytes)} • ${_formatSharedMediaMoment(item.messageCreatedAt)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => unawaited(_openItem(item)),
                      );
                    },
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemCount: _items.length,
                  ),
          ),
        ],
      ),
    );
  }
}

String _formatSharedMediaMoment(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$day.$month ${local.year} • $hour:$minute';
}
