import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api.dart';
import '../../../models.dart';
import '../data/chats_local_cache.dart';

@immutable
class ChatListVmArgs {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;

  const ChatListVmArgs({
    required this.api,
    required this.getTokens,
    required this.me,
  });

  @override
  bool operator ==(Object other) {
    return other is ChatListVmArgs &&
        other.api.baseUrl == api.baseUrl &&
        other.me.id == me.id;
  }

  @override
  int get hashCode => Object.hash(api.baseUrl, me.id);
}

@immutable
class ChatThreadVmArgs {
  final AstraApi api;
  final AuthTokens? Function() getTokens;
  final AppUser me;
  final int chatId;

  const ChatThreadVmArgs({
    required this.api,
    required this.getTokens,
    required this.me,
    required this.chatId,
  });

  @override
  bool operator ==(Object other) {
    return other is ChatThreadVmArgs &&
        other.api.baseUrl == api.baseUrl &&
        other.me.id == me.id &&
        other.chatId == chatId;
  }

  @override
  int get hashCode => Object.hash(api.baseUrl, me.id, chatId);
}

final chatListViewModelProvider = ChangeNotifierProvider.autoDispose
    .family<ChatListViewModel, ChatListVmArgs>(
      (ref, args) => ChatListViewModel(
        api: args.api,
        getTokens: args.getTokens,
        me: args.me,
        cache: ChatsLocalCache(),
      ),
    );

final chatThreadViewModelProvider = ChangeNotifierProvider.autoDispose
    .family<ChatThreadViewModel, ChatThreadVmArgs>(
      (ref, args) => ChatThreadViewModel(
        api: args.api,
        getTokens: args.getTokens,
        me: args.me,
        chatId: args.chatId,
        cache: ChatsLocalCache(),
      ),
    );

class ChatListViewModel extends ChangeNotifier {
  final AstraApi _api;
  final AuthTokens? Function() _getTokens;
  final AppUser _me;
  final ChatsLocalCache _cache;

  bool loading = true;
  List<ChatItem> allChats = const [];
  bool searchingMessages = false;
  List<MessageSearchHit> messageHits = const [];
  String activeFilter = 'all';
  String? activeFolder;

  ChatListViewModel({
    required AstraApi api,
    required AuthTokens? Function() getTokens,
    required AppUser me,
    required ChatsLocalCache cache,
  }) : _api = api,
       _getTokens = getTokens,
       _me = me,
       _cache = cache;

  Future<void> prime() async {
    await _loadCachedChats();
    await loadChats();
  }

  Future<void> _loadCachedChats() async {
    final cached = await _cache.loadChats(
      baseUrl: _api.baseUrl,
      userId: _me.id,
    );
    if (cached.isEmpty) return;
    allChats = cached;
    loading = false;
    notifyListeners();
  }

  Future<String?> loadChats({bool silent = false}) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    if (!silent && allChats.isEmpty) {
      loading = true;
      notifyListeners();
    }
    try {
      final chats = await _api.listChats(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        includeArchived: true,
      );
      allChats = chats;
      await _cache.saveChats(
        baseUrl: _api.baseUrl,
        userId: _me.id,
        chats: chats,
      );
      return null;
    } catch (error) {
      if (!silent && allChats.isEmpty) {
        return error.toString();
      }
      return null;
    } finally {
      if (!silent) {
        loading = false;
        notifyListeners();
      } else {
        notifyListeners();
      }
    }
  }

  Future<String?> searchInMessages(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) {
      messageHits = const [];
      notifyListeners();
      return null;
    }
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    searchingMessages = true;
    notifyListeners();
    try {
      final hits = await _api.searchMessages(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        query: cleaned,
      );
      messageHits = hits;
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      searchingMessages = false;
      notifyListeners();
    }
  }

  void clearMessageHits() {
    if (messageHits.isEmpty) return;
    messageHits = const [];
    notifyListeners();
  }

  void setFilter(String filter) {
    if (activeFilter == filter) return;
    activeFilter = filter;
    notifyListeners();
  }

  void setFolderFilter(String? folder) {
    final normalized = folder?.trim().toLowerCase();
    if (activeFolder == normalized) return;
    activeFolder = normalized;
    notifyListeners();
  }

  List<String> availableFolders() {
    final values = allChats
        .map((chat) => chat.folder?.trim().toLowerCase())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return values;
  }

  List<ChatItem> filteredChats(String query) {
    final scoped = switch (activeFilter) {
      'pinned' => allChats.where((chat) => chat.isPinned).toList(),
      'archived' => allChats.where((chat) => chat.isArchived).toList(),
      'unread' =>
        allChats
            .where((chat) => !chat.isArchived && chat.unreadCount > 0)
            .toList(),
      _ => allChats.where((chat) => !chat.isArchived).toList(),
    };
    final folderScoped = activeFolder == null
        ? scoped
        : scoped.where((chat) => (chat.folder ?? '').trim().toLowerCase() == activeFolder).toList();
    final cleaned = query.trim().toLowerCase();
    if (cleaned.isEmpty) return folderScoped;
    return folderScoped.where((chat) {
      return chat.title.toLowerCase().contains(cleaned) ||
          (chat.lastMessagePreview ?? '').toLowerCase().contains(cleaned);
    }).toList();
  }
}

class ChatThreadViewModel extends ChangeNotifier {
  final AstraApi _api;
  final AuthTokens? Function() _getTokens;
  final AppUser _me;
  final int _chatId;
  final ChatsLocalCache _cache;

  bool loading = true;
  bool loadingMore = false;
  bool loadingScheduled = false;
  bool searchingInChat = false;
  bool sending = false;
  List<MessageItem> messages = const [];
  List<ScheduledMessageItem> scheduledMessages = const [];
  List<MessageSearchHit> chatMessageHits = const [];
  int? highlightedMessageId;
  int? nextBeforeId;
  Timer? _persistDebounce;
  bool _flushingOutbox = false;
  List<MessageItem> _outboxMessages = const [];
  int _localMessageSeed = 0;

  String _nextClientMessageId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'm_${_chatId}_${_me.id}_$now';
  }

  int _nextLocalMessageId() {
    if (_localMessageSeed >= 0) {
      _localMessageSeed = -1;
    } else {
      _localMessageSeed -= 1;
    }
    while (messages.any((row) => row.id == _localMessageSeed)) {
      _localMessageSeed -= 1;
    }
    return _localMessageSeed;
  }

  ChatThreadViewModel({
    required AstraApi api,
    required AuthTokens? Function() getTokens,
    required AppUser me,
    required int chatId,
    required ChatsLocalCache cache,
  }) : _api = api,
       _getTokens = getTokens,
       _me = me,
       _chatId = chatId,
       _cache = cache;

  Future<void> prime() async {
    await _loadCachedMessages();
    await _loadCachedOutboxMessages();
    await loadMessages();
    await loadScheduledMessages(silent: true);
    unawaited(flushPendingOutbox());
  }

  Future<void> _loadCachedMessages() async {
    final cached = await _cache.loadMessages(
      baseUrl: _api.baseUrl,
      userId: _me.id,
      chatId: _chatId,
    );
    if (cached.isEmpty) return;
    messages = cached;
    _reseedLocalMessageIds(messages);
    loading = false;
    notifyListeners();
  }

  Future<void> _loadCachedOutboxMessages() async {
    final cached = await _cache.loadOutboxMessages(
      baseUrl: _api.baseUrl,
      userId: _me.id,
      chatId: _chatId,
    );
    if (cached.isEmpty) return;
    _outboxMessages = cached
        .map(
          (row) => _normalizeOutboxMessage(
            row.status == 'sending' ? row.copyWith(status: 'pending') : row,
          ),
        )
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    messages = _mergeVisibleMessages(messages, _outboxMessages);
    _reseedLocalMessageIds(messages);
    _schedulePersistMessages();
    notifyListeners();
  }

  Future<String?> loadMessages({bool silent = false}) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    if (!silent && messages.isEmpty) {
      loading = true;
      notifyListeners();
    }
    try {
      final page = await _api.listMessagesCursor(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        limit: 60,
      );
      final rows = [...page.items]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _dropAckedOutboxEntries(rows);
      messages = _mergeVisibleMessages(rows, _outboxMessages);
      _reseedLocalMessageIds(messages);
      nextBeforeId = page.nextBeforeId;
      _schedulePersistMessages();
      unawaited(flushPendingOutbox());
      return null;
    } catch (error) {
      if (messages.isEmpty) return error.toString();
      return null;
    } finally {
      if (!silent) {
        loading = false;
      }
      notifyListeners();
    }
  }

  Future<String?> loadScheduledMessages({bool silent = false}) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    if (!silent) {
      loadingScheduled = true;
      notifyListeners();
    }
    try {
      final rows = await _api.listScheduledMessages(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        limit: 100,
      );
      scheduledMessages = [...rows]
        ..sort((a, b) => a.scheduledFor.compareTo(b.scheduledFor));
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      if (!silent) {
        loadingScheduled = false;
        notifyListeners();
      } else {
        notifyListeners();
      }
    }
  }

  Future<String?> loadMoreHistory() async {
    if (loadingMore || nextBeforeId == null) return null;
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';

    loadingMore = true;
    notifyListeners();
    try {
      final page = await _api.listMessagesCursor(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        limit: 50,
        beforeId: nextBeforeId,
      );
      nextBeforeId = page.nextBeforeId;
      if (page.items.isEmpty) return null;

      final existingIds = messages.map((row) => row.id).toSet();
      final merged = [
        ...page.items.where((row) => !existingIds.contains(row.id)),
        ...messages,
      ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      messages = merged;
      _reseedLocalMessageIds(messages);
      _schedulePersistMessages();
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }

  Future<String?> searchInCurrentChat(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) {
      chatMessageHits = const [];
      notifyListeners();
      return null;
    }
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    searchingInChat = true;
    notifyListeners();
    try {
      final hits = await _api.searchChatMessages(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        query: cleaned,
      );
      chatMessageHits = hits;
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      searchingInChat = false;
      notifyListeners();
    }
  }

  void clearInChatSearch() {
    if (chatMessageHits.isEmpty && highlightedMessageId == null) return;
    chatMessageHits = const [];
    highlightedMessageId = null;
    notifyListeners();
  }

  Future<String?> openMessageContext(int messageId) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      final page = await _api.messageContext(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        messageId: messageId,
      );
      final mergedById = <int, MessageItem>{
        for (final row in messages.where((item) => item.id > 0)) row.id: row,
        for (final row in page.items) row.id: row,
      };
      final serverMessages = mergedById.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _dropAckedOutboxEntries(serverMessages);
      messages = _mergeVisibleMessages(serverMessages, _outboxMessages);
      nextBeforeId = page.nextBeforeId;
      highlightedMessageId = page.anchorMessageId;
      _reseedLocalMessageIds(messages);
      _schedulePersistMessages();
      notifyListeners();
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  void clearHighlightedMessage() {
    if (highlightedMessageId == null) return;
    highlightedMessageId = null;
    notifyListeners();
  }

  Future<String?> sendMessage(
    String text, {
    int? replyToMessageId,
    int? forwardFromMessageId,
    List<int> attachmentIds = const [],
    List<MessageAttachmentItem> attachments = const [],
    bool isSilent = false,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty && attachmentIds.isEmpty && forwardFromMessageId == null) return null;
    if (_getTokens() == null) return 'Session expired';

    final now = DateTime.now().toUtc();
    final clientMessageId = _nextClientMessageId();
    final optimistic = MessageItem(
      id: _nextLocalMessageId(),
      chatId: _chatId,
      senderId: _me.id,
      content: cleaned,
      clientMessageId: clientMessageId,
      createdAt: now,
      status: 'pending',
      editedAt: null,
      replyToMessageId: replyToMessageId,
      forwardedFromMessageId: forwardFromMessageId,
      isSilent: isSilent,
      isPinned: false,
      reactions: const [],
      attachments: attachments,
    );
    _upsertOutboxMessage(optimistic);
    applyUpdatedMessage(optimistic, notify: false);
    notifyListeners();
    unawaited(flushPendingOutbox());
    return null;
  }

  Future<void> flushPendingOutbox({bool includeFailed = false}) async {
    if (_flushingOutbox || _outboxMessages.isEmpty) return;
    final tokens = _getTokens();
    if (tokens == null) return;

    final queue = [..._outboxMessages]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _flushingOutbox = true;
    _setSending(true, notify: true);
    try {
      for (final localMessage in queue) {
        if (!_shouldAttemptOutboxMessage(localMessage, includeFailed: includeFailed)) {
          continue;
        }
        final clientMessageId = localMessage.clientMessageId;
        if (clientMessageId == null || clientMessageId.isEmpty) continue;

        _setLocalMessageStatus(clientMessageId: clientMessageId, status: 'sending', notify: true);
        try {
          final sent = await _api.sendMessage(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            chatId: _chatId,
            content: localMessage.content,
            replyToMessageId: localMessage.replyToMessageId,
            forwardFromMessageId: localMessage.forwardedFromMessageId,
            attachmentIds: localMessage.attachments.map((row) => row.id).toList(),
            clientMessageId: clientMessageId,
            isSilent: localMessage.isSilent,
          );
          applyUpdatedMessage(sent, notify: true);
        } catch (_) {
          _setLocalMessageStatus(clientMessageId: clientMessageId, status: 'failed', notify: true);
        }
      }
    } finally {
      _flushingOutbox = false;
      _setSending(false, notify: true);
    }
  }

  Future<String?> retryFailedMessage({required MessageItem message}) async {
    final clientMessageId = message.clientMessageId;
    if (clientMessageId == null || clientMessageId.isEmpty) {
      return 'This message cannot be retried';
    }
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    _setLocalMessageStatus(clientMessageId: clientMessageId, status: 'pending', notify: true);
    await flushPendingOutbox(includeFailed: true);
    return null;
  }

  Future<void> cancelPendingMessage(MessageItem message) async {
    final clientMessageId = message.clientMessageId;
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      _outboxMessages = _outboxMessages
          .where((row) => row.clientMessageId != clientMessageId)
          .toList();
    }
    messages = messages.where((row) {
      if (clientMessageId != null && clientMessageId.isNotEmpty) {
        return row.clientMessageId != clientMessageId;
      }
      return row.id != message.id;
    }).toList();
    await _persistOutboxMessages();
    _schedulePersistMessages();
    notifyListeners();
  }

  Future<String?> sendScheduledMessage(
    String text, {
    DateTime? scheduledFor,
    bool sendWhenUserOnline = false,
    int? replyToMessageId,
    List<int> attachmentIds = const [],
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty && attachmentIds.isEmpty) return null;
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';

    _setSending(true, notify: true);
    try {
      final scheduled = await _api.scheduleMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
        content: cleaned,
        scheduledFor: scheduledFor,
        sendWhenUserOnline: sendWhenUserOnline,
        replyToMessageId: replyToMessageId,
        attachmentIds: attachmentIds,
      );
      scheduledMessages = [...scheduledMessages, scheduled]
        ..sort((a, b) => a.scheduledFor.compareTo(b.scheduledFor));
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      if (!_flushingOutbox) {
        _setSending(false, notify: true);
      } else {
        notifyListeners();
      }
    }
  }

  Future<String?> cancelScheduledMessage(int scheduledMessageId) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      final removed = await _api.deleteScheduledMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        scheduledMessageId: scheduledMessageId,
      );
      if (removed) {
        scheduledMessages = scheduledMessages
            .where((row) => row.id != scheduledMessageId)
            .toList();
        notifyListeners();
      }
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<String?> editMessage({
    required int messageId,
    required String text,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return null;
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      final updated = await _api.updateMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        messageId: messageId,
        content: cleaned,
      );
      applyUpdatedMessage(updated);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<String?> deleteRemoteMessage(int messageId, {String scope = 'all'}) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      final removed = await _api.deleteMessage(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        messageId: messageId,
        scope: scope,
      );
      if (removed) {
        deleteMessage(messageId);
      }
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<String?> clearHistoryForMe() async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      await _api.clearChatHistory(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        chatId: _chatId,
      );
      messages = _outboxMessages.where(_isLocalOutboxStatusMessage).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      nextBeforeId = null;
      highlightedMessageId = null;
      chatMessageHits = const [];
      _schedulePersistMessages();
      notifyListeners();
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  bool _isLocalOutboxStatusMessage(MessageItem row) => _isLocalOutboxStatus(row.status);

  Future<String?> setMessagePinned({
    required int messageId,
    required bool pinned,
  }) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      if (pinned) {
        await _api.pinMessage(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          chatId: _chatId,
          messageId: messageId,
        );
      } else {
        await _api.unpinMessage(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          chatId: _chatId,
          messageId: messageId,
        );
      }
      updatePinnedState(messageId: messageId, pinned: pinned);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<String?> toggleReaction({
    required int messageId,
    required String emoji,
    required bool reactedByMe,
  }) async {
    final tokens = _getTokens();
    if (tokens == null) return 'Session expired';
    try {
      if (reactedByMe) {
        await _api.removeReaction(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          messageId: messageId,
          emoji: emoji,
        );
      } else {
        await _api.addReaction(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
          messageId: messageId,
          emoji: emoji,
        );
      }
      await loadMessages(silent: true);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  void applyMessage(MessageItem item) {
    applyUpdatedMessage(item);
  }

  void applyUpdatedMessage(MessageItem item, {bool notify = true}) {
    final normalized = _normalizeOutboxMessage(item);
    final existingIndex = messages.indexWhere((row) {
      if (row.id == normalized.id) return true;
      final clientMessageId = normalized.clientMessageId;
      if (clientMessageId == null || clientMessageId.isEmpty) return false;
      return row.clientMessageId == clientMessageId;
    });
    if (existingIndex == -1) {
      messages = [...messages, normalized]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    } else {
      final next = [...messages];
      next[existingIndex] = normalized;
      next.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      messages = next;
    }

    final clientMessageId = normalized.clientMessageId;
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      final hadOutbox = _outboxMessages.any((row) => row.clientMessageId == clientMessageId);
      if (hadOutbox && !_isLocalOutboxStatus(normalized.status)) {
        _outboxMessages = _outboxMessages
            .where((row) => row.clientMessageId != clientMessageId)
            .toList();
        unawaited(_persistOutboxMessages());
      }
    }
    _reseedLocalMessageIds(messages);
    _schedulePersistMessages();
    if (notify) {
      notifyListeners();
    }
  }

  void deleteMessage(int messageId) {
    final removed = findMessageById(messageId);
    messages = messages.where((row) => row.id != messageId).toList();
    final removedClientMessageId = removed?.clientMessageId;
    if (removedClientMessageId != null && removedClientMessageId.isNotEmpty) {
      _outboxMessages = _outboxMessages
          .where((row) => row.clientMessageId != removedClientMessageId)
          .toList();
      unawaited(_persistOutboxMessages());
    }
    _schedulePersistMessages();
    notifyListeners();
  }

  void updateMessageStatus(int messageId, String status) {
    messages = messages
        .map(
          (row) => row.id == messageId
              ? row.copyWith(status: status)
              : row,
        )
        .toList();
    _schedulePersistMessages();
    notifyListeners();
  }

  void updatePinnedState({required int messageId, required bool pinned}) {
    messages = messages
        .map(
          (row) => row.id == messageId ? row.copyWith(isPinned: pinned) : row,
        )
        .toList();
    _schedulePersistMessages();
    notifyListeners();
  }

  MessageItem? findMessageById(int messageId) {
    for (final message in messages) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  MessageItem? get pinnedMessage {
    MessageItem? pinned;
    for (final message in messages) {
      if (message.isPinned) {
        pinned = message;
      }
    }
    return pinned;
  }

  bool isPendingLocalMessage(MessageItem message) {
    final clientMessageId = message.clientMessageId;
    if (clientMessageId == null || clientMessageId.isEmpty) return false;
    return _outboxMessages.any((row) => row.clientMessageId == clientMessageId);
  }

  void _setLocalMessageStatus({
    required String clientMessageId,
    required String status,
    required bool notify,
  }) {
    _outboxMessages = _outboxMessages
        .map(
          (row) => row.clientMessageId == clientMessageId
              ? row.copyWith(status: status)
              : row,
        )
        .toList();
    messages = messages
        .map(
          (row) => row.clientMessageId == clientMessageId
              ? row.copyWith(status: status)
              : row,
        )
        .toList();
    _schedulePersistMessages();
    unawaited(_persistOutboxMessages());
    if (notify) {
      notifyListeners();
    }
  }

  void _upsertOutboxMessage(MessageItem item) {
    final normalized = _normalizeOutboxMessage(item);
    final clientMessageId = normalized.clientMessageId;
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      final index = _outboxMessages.indexWhere((row) => row.clientMessageId == clientMessageId);
      if (index == -1) {
        _outboxMessages = [..._outboxMessages, normalized]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      } else {
        final next = [..._outboxMessages];
        next[index] = normalized;
        next.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _outboxMessages = next;
      }
    }
    unawaited(_persistOutboxMessages());
  }

  void _dropAckedOutboxEntries(Iterable<MessageItem> remoteRows) {
    final remoteClientIds = remoteRows
        .map((row) => row.clientMessageId)
        .whereType<String>()
        .where((row) => row.isNotEmpty)
        .toSet();
    if (remoteClientIds.isEmpty) return;
    final nextOutbox = _outboxMessages
        .where((row) => !remoteClientIds.contains(row.clientMessageId))
        .toList();
    if (nextOutbox.length == _outboxMessages.length) return;
    _outboxMessages = nextOutbox;
    unawaited(_persistOutboxMessages());
  }

  List<MessageItem> _mergeVisibleMessages(
    List<MessageItem> remoteRows,
    List<MessageItem> outboxRows,
  ) {
    final merged = <MessageItem>[];
    final seenIds = <int>{};
    final seenClientMessageIds = <String>{};

    for (final row in remoteRows) {
      merged.add(row);
      seenIds.add(row.id);
      final clientMessageId = row.clientMessageId;
      if (clientMessageId != null && clientMessageId.isNotEmpty) {
        seenClientMessageIds.add(clientMessageId);
      }
    }

    for (final row in outboxRows) {
      final clientMessageId = row.clientMessageId;
      if (seenIds.contains(row.id)) continue;
      if (clientMessageId != null && clientMessageId.isNotEmpty) {
        if (seenClientMessageIds.contains(clientMessageId)) continue;
        seenClientMessageIds.add(clientMessageId);
      }
      merged.add(row);
      seenIds.add(row.id);
    }

    merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return merged;
  }

  MessageItem _normalizeOutboxMessage(MessageItem item) {
    if (_isLocalOutboxStatus(item.status)) return item;
    if (item.id < 0 && item.clientMessageId != null && item.clientMessageId!.isNotEmpty) {
      return item.copyWith(status: 'pending');
    }
    return item;
  }

  bool _shouldAttemptOutboxMessage(
    MessageItem message, {
    required bool includeFailed,
  }) {
    return switch (message.status) {
      'pending' || 'sending' => true,
      'failed' => includeFailed,
      _ => false,
    };
  }

  bool _isLocalOutboxStatus(String status) {
    return status == 'pending' || status == 'sending' || status == 'failed';
  }

  void _reseedLocalMessageIds(List<MessageItem> rows) {
    var minLocalId = 0;
    for (final row in rows) {
      if (row.id < minLocalId) {
        minLocalId = row.id;
      }
    }
    _localMessageSeed = minLocalId;
  }

  void _schedulePersistMessages() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 300), () async {
      await _cache.saveMessages(
        baseUrl: _api.baseUrl,
        userId: _me.id,
        chatId: _chatId,
        messages: messages,
      );
    });
  }

  Future<void> _persistOutboxMessages() async {
    await _cache.saveOutboxMessages(
      baseUrl: _api.baseUrl,
      userId: _me.id,
      chatId: _chatId,
      messages: _outboxMessages,
    );
  }

  void _setSending(bool value, {required bool notify}) {
    if (sending == value) {
      if (notify) {
        notifyListeners();
      }
      return;
    }
    sending = value;
    if (notify) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    super.dispose();
  }
}
