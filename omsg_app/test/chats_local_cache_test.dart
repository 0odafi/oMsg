import 'package:omsg_app/src/features/chats/data/chats_local_cache.dart';
import 'package:omsg_app/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('chats cache roundtrip', () async {
    final cache = ChatsLocalCache();
    final now = DateTime.utc(2026, 3, 9, 12, 0, 0);
    final chats = [
      ChatItem(
        id: 10,
        title: 'Alice',
        type: 'private',
        lastMessagePreview: 'Hi',
        lastMessageAt: now,
        unreadCount: 2,
        isArchived: false,
        isPinned: true,
        folder: null,
      ),
    ];

    await cache.saveChats(baseUrl: 'https://volds.ru', userId: 1, chats: chats);
    final loaded = await cache.loadChats(
      baseUrl: 'https://volds.ru',
      userId: 1,
    );

    expect(loaded, hasLength(1));
    expect(loaded.first.id, 10);
    expect(loaded.first.title, 'Alice');
    expect(loaded.first.unreadCount, 2);
    expect(loaded.first.isPinned, true);
  });

  test('messages cache keeps recent tail', () async {
    final cache = ChatsLocalCache();
    final rows = List<MessageItem>.generate(
      5,
      (index) => MessageItem(
        id: index + 1,
        chatId: 7,
        senderId: 1,
        content: 'm${index + 1}',
        clientMessageId: null,
        createdAt: DateTime.utc(2026, 3, 9, 12, 0, index),
        status: 'sent',
        editedAt: null,
      ),
    );

    await cache.saveMessages(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 7,
      messages: rows,
      maxItems: 3,
    );
    final loaded = await cache.loadMessages(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 7,
    );

    expect(loaded, hasLength(3));
    expect(loaded.first.id, 3);
    expect(loaded.last.id, 5);
    expect(loaded.last.content, 'm5');
  });

  test('messages cache preserves reply pin reactions and attachments', () async {
    final cache = ChatsLocalCache();
    final rows = <MessageItem>[
      MessageItem(
        id: 50,
        chatId: 9,
        senderId: 2,
        content: 'photo',
        clientMessageId: null,
        createdAt: DateTime.utc(2026, 3, 9, 14, 10, 0),
        status: 'read',
        editedAt: DateTime.utc(2026, 3, 9, 14, 11, 0),
        replyToMessageId: 44,
        isPinned: true,
        reactions: const [
          MessageReactionItem(emoji: '🔥', count: 3, reactedByMe: true),
        ],
        attachments: const [
          MessageAttachmentItem(
            id: 7,
            fileName: 'cover.png',
            mimeType: 'image/png',
            mediaKind: 'image',
            sizeBytes: 2048,
            url: '/media/cover.png',
            isImage: true,
            isAudio: false,
            isVideo: false,
            isVoice: false,
            width: null,
            height: null,
            durationSeconds: null,
            thumbnailUrl: null,
          ),
        ],
      ),
    ];

    await cache.saveMessages(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 9,
      messages: rows,
    );
    final loaded = await cache.loadMessages(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 9,
    );

    expect(loaded, hasLength(1));
    expect(loaded.first.replyToMessageId, 44);
    expect(loaded.first.isPinned, true);
    expect(loaded.first.reactions.single.emoji, '🔥');
    expect(loaded.first.attachments.single.fileName, 'cover.png');
  });
}
