import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/ui/app_appearance.dart';

class AppPreferencesStore {
  static const _surfaceKey = 'omsg.pref.chat_surface';
  static const _accentKey = 'omsg.pref.chat_accent';
  static const _scaleKey = 'omsg.pref.message_scale';
  static const _compactKey = 'omsg.pref.chat_compact';

  Future<AppAppearanceData> load() async {
    final prefs = await SharedPreferences.getInstance();
    final surfaceRaw = prefs.getString(_surfaceKey);
    final accentRaw = prefs.getString(_accentKey);
    final scaleRaw = prefs.getDouble(_scaleKey);
    final compactRaw = prefs.getBool(_compactKey);

    return AppAppearanceData(
      chatSurfacePreset: _parseSurface(surfaceRaw),
      chatAccentPreset: _parseAccent(accentRaw),
      messageTextScale: (scaleRaw ?? 1.0).clamp(0.9, 1.3),
      compactChatList: compactRaw ?? false,
    );
  }

  Future<void> save(AppAppearanceData data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_surfaceKey, data.chatSurfacePreset.name);
    await prefs.setString(_accentKey, data.chatAccentPreset.name);
    await prefs.setDouble(_scaleKey, data.messageTextScale);
    await prefs.setBool(_compactKey, data.compactChatList);
  }

  ChatSurfacePreset _parseSurface(String? raw) {
    return ChatSurfacePreset.values.firstWhere(
      (preset) => preset.name == raw,
      orElse: () => ChatSurfacePreset.ocean,
    );
  }

  ChatAccentPreset _parseAccent(String? raw) {
    return ChatAccentPreset.values.firstWhere(
      (preset) => preset.name == raw,
      orElse: () => ChatAccentPreset.blue,
    );
  }
}
