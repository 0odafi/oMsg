import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/app_appearance.dart';
import '../data/app_preferences_store.dart';

final appPreferencesProvider = ChangeNotifierProvider<AppPreferencesController>(
  (ref) => AppPreferencesController()..load(),
);

class AppPreferencesController extends ChangeNotifier {
  AppPreferencesController({AppPreferencesStore? store})
    : _store = store ?? AppPreferencesStore();

  final AppPreferencesStore _store;
  AppAppearanceData _appearance = const AppAppearanceData.defaults();
  bool _loading = true;

  AppAppearanceData get appearance => _appearance;
  bool get loading => _loading;

  Future<void> load() async {
    final next = await _store.load();
    _appearance = next;
    _loading = false;
    notifyListeners();
  }

  Future<void> setChatSurfacePreset(ChatSurfacePreset preset) {
    return _update(_appearance.copyWith(chatSurfacePreset: preset));
  }

  Future<void> setChatAccentPreset(ChatAccentPreset preset) {
    return _update(_appearance.copyWith(chatAccentPreset: preset));
  }

  Future<void> setMessageTextScale(double value) {
    return _update(
      _appearance.copyWith(messageTextScale: value.clamp(0.9, 1.3).toDouble()),
    );
  }

  Future<void> setCompactChatList(bool enabled) {
    return _update(_appearance.copyWith(compactChatList: enabled));
  }

  Future<void> _update(AppAppearanceData next) async {
    _appearance = next;
    notifyListeners();
    unawaited(_store.save(next));
  }
}
