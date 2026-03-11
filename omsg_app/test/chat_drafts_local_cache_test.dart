import 'package:omsg_app/src/features/chats/data/chat_drafts_local_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('save and load chat draft', () async {
    final cache = ChatDraftsLocalCache();
    await cache.saveDraft(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 11,
      text: 'hello draft',
    );

    final loaded = await cache.loadDraft(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 11,
    );
    expect(loaded, 'hello draft');
  });

  test('empty text removes draft', () async {
    final cache = ChatDraftsLocalCache();
    await cache.saveDraft(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 11,
      text: 'to remove',
    );
    await cache.saveDraft(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 11,
      text: '',
    );

    final loaded = await cache.loadDraft(
      baseUrl: 'https://volds.ru',
      userId: 1,
      chatId: 11,
    );
    expect(loaded, isNull);
  });
}
