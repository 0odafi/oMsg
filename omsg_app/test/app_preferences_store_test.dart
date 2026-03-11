import 'package:omsg_app/src/core/ui/app_appearance.dart';
import 'package:omsg_app/src/features/settings/data/app_preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads defaults when preferences are empty', () async {
    final store = AppPreferencesStore();
    final loaded = await store.load();

    expect(loaded.chatSurfacePreset, ChatSurfacePreset.ocean);
    expect(loaded.chatAccentPreset, ChatAccentPreset.blue);
    expect(loaded.messageTextScale, 1.0);
    expect(loaded.compactChatList, isFalse);
  });

  test('saves and restores appearance settings', () async {
    final store = AppPreferencesStore();
    final expected = AppAppearanceData(
      chatSurfacePreset: ChatSurfacePreset.amoled,
      chatAccentPreset: ChatAccentPreset.violet,
      messageTextScale: 1.2,
      compactChatList: true,
    );

    await store.save(expected);
    final loaded = await store.load();

    expect(loaded.chatSurfacePreset, ChatSurfacePreset.amoled);
    expect(loaded.chatAccentPreset, ChatAccentPreset.violet);
    expect(loaded.messageTextScale, 1.2);
    expect(loaded.compactChatList, isTrue);
  });
}
