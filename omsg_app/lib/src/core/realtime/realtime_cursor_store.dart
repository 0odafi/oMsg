import 'package:shared_preferences/shared_preferences.dart';

class RealtimeCursorStore {
  static const _prefix = 'omsg.realtime.cursor';

  String _key({required String baseUrl, required int userId}) =>
      '$_prefix::$baseUrl::$userId';

  Future<int> loadCursor({required String baseUrl, required int userId}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_key(baseUrl: baseUrl, userId: userId)) ?? 0;
  }

  Future<void> saveCursor({
    required String baseUrl,
    required int userId,
    required int cursor,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(baseUrl: baseUrl, userId: userId);
    final current = prefs.getInt(key) ?? 0;
    if (cursor <= current) return;
    await prefs.setInt(key, cursor);
  }

  Future<void> clearCursor({
    required String baseUrl,
    required int userId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(baseUrl: baseUrl, userId: userId));
  }
}
