import 'package:omsg_app/src/core/realtime/realtime_cursor_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores and restores max realtime cursor', () async {
    final store = RealtimeCursorStore();
    await store.saveCursor(baseUrl: 'https://volds.ru', userId: 7, cursor: 14);
    await store.saveCursor(baseUrl: 'https://volds.ru', userId: 7, cursor: 11);

    final loaded = await store.loadCursor(
      baseUrl: 'https://volds.ru',
      userId: 7,
    );
    expect(loaded, 14);
  });
}
