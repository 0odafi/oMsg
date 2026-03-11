import 'package:shared_preferences/shared_preferences.dart';

class ChatDraftsLocalCache {
  static const String _draftPrefix = 'omsg.cache.v1.chat_draft';

  final Future<SharedPreferences> Function() _prefsFactory;

  ChatDraftsLocalCache({Future<SharedPreferences> Function()? prefsFactory})
    : _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  Future<String?> loadDraft({
    required String baseUrl,
    required int userId,
    required int chatId,
  }) async {
    final prefs = await _prefsFactory();
    return prefs.getString(
      _key(baseUrl: baseUrl, userId: userId, chatId: chatId),
    );
  }

  Future<void> saveDraft({
    required String baseUrl,
    required int userId,
    required int chatId,
    required String text,
  }) async {
    final prefs = await _prefsFactory();
    final key = _key(baseUrl: baseUrl, userId: userId, chatId: chatId);
    final normalized = text.trimRight();
    if (normalized.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, text);
  }

  Future<void> clearDraft({
    required String baseUrl,
    required int userId,
    required int chatId,
  }) async {
    final prefs = await _prefsFactory();
    await prefs.remove(_key(baseUrl: baseUrl, userId: userId, chatId: chatId));
  }

  String _key({
    required String baseUrl,
    required int userId,
    required int chatId,
  }) {
    return '$_draftPrefix::$baseUrl::$userId::$chatId';
  }
}
