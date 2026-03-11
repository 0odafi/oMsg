import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

class SessionSnapshot {
  final String baseUrl;
  final String? accessToken;
  final String? refreshToken;
  final String updateChannel;
  final bool needsProfileSetup;

  const SessionSnapshot({
    required this.baseUrl,
    required this.accessToken,
    required this.refreshToken,
    required this.updateChannel,
    required this.needsProfileSetup,
  });

  bool get isAuthenticated => accessToken != null && accessToken!.isNotEmpty;
}

class SessionStore {
  static const _kBaseUrl = 'omsg_base_url';
  static const _kAccessToken = 'omsg_access_token';
  static const _kRefreshToken = 'omsg_refresh_token';
  static const _kUpdateChannel = 'omsg_update_channel';
  static const _kNeedsProfileSetup = 'omsg_needs_profile_setup';

  Future<SessionSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = normalizeBaseUrl(
      prefs.getString(_kBaseUrl) ?? kDefaultApiBaseUrl,
    );
    final accessToken = prefs.getString(_kAccessToken);
    final refreshToken = prefs.getString(_kRefreshToken);
    final updateChannel = prefs.getString(_kUpdateChannel) ?? 'stable';
    final needsProfileSetup = prefs.getBool(_kNeedsProfileSetup) ?? false;
    await prefs.setString(_kBaseUrl, baseUrl);

    return SessionSnapshot(
      baseUrl: baseUrl,
      accessToken: accessToken,
      refreshToken: refreshToken,
      updateChannel: updateChannel,
      needsProfileSetup: needsProfileSetup,
    );
  }

  Future<void> saveSession({
    required String baseUrl,
    required AuthTokens? tokens,
    bool needsProfileSetup = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, normalizeBaseUrl(baseUrl));
    if (tokens == null) {
      await prefs.remove(_kAccessToken);
      await prefs.remove(_kRefreshToken);
      await prefs.remove(_kNeedsProfileSetup);
      return;
    }
    await prefs.setString(_kAccessToken, tokens.accessToken);
    await prefs.setString(_kRefreshToken, tokens.refreshToken);
    await prefs.setBool(_kNeedsProfileSetup, needsProfileSetup);
  }

  Future<void> saveUpdateChannel(String channel) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUpdateChannel, channel);
  }
}
