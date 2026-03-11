import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ChatComposerQueueLocalCache {
  static const String _prefix = 'omsg.cache.v1.chat_composer_queue';

  final Future<SharedPreferences> Function() _prefsFactory;

  ChatComposerQueueLocalCache({Future<SharedPreferences> Function()? prefsFactory})
    : _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  Future<List<Map<String, dynamic>>> loadQueue({
    required String baseUrl,
    required int userId,
    required int chatId,
  }) async {
    final prefs = await _prefsFactory();
    final raw = prefs.getString(
      _key(baseUrl: baseUrl, userId: userId, chatId: chatId),
    );
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((row) => row.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveQueue({
    required String baseUrl,
    required int userId,
    required int chatId,
    required List<Map<String, dynamic>> items,
  }) async {
    final prefs = await _prefsFactory();
    final key = _key(baseUrl: baseUrl, userId: userId, chatId: chatId);
    if (items.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, jsonEncode(items));
  }

  Future<void> clearQueue({
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
    return '$_prefix::$baseUrl::$userId::$chatId';
  }
}
