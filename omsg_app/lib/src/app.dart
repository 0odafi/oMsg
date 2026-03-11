import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'api.dart';
import 'core/deep_links/deep_link_source.dart';
import 'core/ui/adaptive_size.dart';
import 'core/ui/app_theme.dart';
import 'features/auth/presentation/auth_screen.dart';
import 'features/home/presentation/home_shell.dart';
import 'features/profile/presentation/profile_setup_screen.dart';
import 'features/profile/presentation/public_profile_screen.dart';
import 'features/settings/application/app_preferences.dart';
import 'models.dart';
import 'session.dart';

class AstraMessengerApp extends StatefulWidget {
  final DeepLinkSource deepLinkSource;

  const AstraMessengerApp({
    super.key,
    this.deepLinkSource = const NoopDeepLinkSource(),
  });

  @override
  State<AstraMessengerApp> createState() => _AstraMessengerAppState();
}

class _AstraMessengerAppState extends State<AstraMessengerApp> {
  final SessionStore _store = SessionStore();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  bool _loading = true;
  String _baseUrl = normalizeBaseUrl(kDefaultApiBaseUrl);
  String _updateChannel = 'stable';
  String _appVersion = '0.0.0+0';
  AuthTokens? _tokens;
  AppUser? _user;
  bool _needsProfileSetup = false;
  String? _pendingPublicUsername;
  String? _lastHandledDeepLink;
  StreamSubscription<Uri>? _deepLinkSubscription;

  AstraApi get _api =>
      AstraApi(baseUrl: _baseUrl, onRefreshToken: _refreshFromApi);

  @override
  void initState() {
    super.initState();
    _bindDeepLinks();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _deepLinkSubscription?.cancel();
    super.dispose();
  }

  void _bindDeepLinks() {
    _deepLinkSubscription = widget.deepLinkSource.uriStream.listen(
      _handleDeepLinkUri,
      onError: (_) {},
    );
  }

  Future<void> _bootstrap() async {
    final info = await PackageInfo.fromPlatform();
    final session = await _store.load();
    _baseUrl = session.baseUrl;
    _updateChannel = session.updateChannel;
    _appVersion = '${info.version}+${info.buildNumber}';
    _needsProfileSetup = session.needsProfileSetup;

    if (session.isAuthenticated) {
      _tokens = AuthTokens(
        accessToken: session.accessToken!,
        refreshToken: session.refreshToken ?? '',
      );
      await _loadCurrentUser();
    }

    final initialUri = await widget.deepLinkSource.getInitialUri();
    if (initialUri != null) {
      _handleDeepLinkUri(initialUri);
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
    });
    _flushPendingPublicProfile();
  }

  Future<AuthTokens?> _refreshFromApi(String refreshToken) async {
    try {
      final refreshed = await _api.refreshSession(refreshToken);
      _tokens = refreshed.tokens;
      _user = refreshed.user;
      _needsProfileSetup = _needsProfileSetup || refreshed.needsProfileSetup;
      await _store.saveSession(
        baseUrl: _baseUrl,
        tokens: _tokens,
        needsProfileSetup: _needsProfileSetup,
      );
      if (mounted) setState(() {});
      return _tokens;
    } catch (_) {
      await _performLogout();
      return null;
    }
  }

  Future<void> _loadCurrentUser() async {
    if (_tokens == null) return;
    try {
      final me = await _api.me(
        accessToken: _tokens!.accessToken,
        refreshToken: _tokens!.refreshToken,
      );
      _user = me;
    } catch (_) {
      await _performLogout();
    }
  }

  Future<void> _onAuthorized(AuthResult result) async {
    _tokens = result.tokens;
    _user = result.user;
    _needsProfileSetup = result.needsProfileSetup;
    await _store.saveSession(
      baseUrl: _baseUrl,
      tokens: _tokens,
      needsProfileSetup: _needsProfileSetup,
    );
    if (!mounted) return;
    setState(() {});
    _flushPendingPublicProfile();
  }

  Future<void> _onUserUpdated(AppUser next) async {
    _user = next;
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _completeProfileSetup(AppUser next) async {
    _user = next;
    _needsProfileSetup = false;
    await _store.saveSession(
      baseUrl: _baseUrl,
      tokens: _tokens,
      needsProfileSetup: false,
    );
    if (!mounted) return;
    setState(() {});
    _flushPendingPublicProfile();
  }

  Future<void> _performLogout() async {
    _tokens = null;
    _user = null;
    _needsProfileSetup = false;
    await _store.saveSession(baseUrl: _baseUrl, tokens: null);
    if (!mounted) return;
    setState(() {});
    _flushPendingPublicProfile();
  }

  Future<void> _changeUpdateChannel(String channel) async {
    _updateChannel = channel;
    await _store.saveUpdateChannel(channel);
    if (!mounted) return;
    setState(() {});
  }

  void _handleDeepLinkUri(Uri uri) {
    final serialized = uri.toString();
    if (_lastHandledDeepLink == serialized) {
      return;
    }
    _lastHandledDeepLink = serialized;

    final username = publicProfileUsernameFromUri(uri);
    if (username == null || username.isEmpty) {
      return;
    }

    _pendingPublicUsername = username;
    _flushPendingPublicProfile();
  }

  void _flushPendingPublicProfile() {
    if (_loading || _pendingPublicUsername == null) {
      return;
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _flushPendingPublicProfile();
      });
      return;
    }

    final username = _pendingPublicUsername!;
    _pendingPublicUsername = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      navigator.push(
        MaterialPageRoute(
          builder: (_) => PublicProfileScreen(
            api: _api,
            getTokens: () => _tokens,
            username: username,
            viewer: _user,
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final appearance = ref.watch(appPreferencesProvider).appearance;
        return MaterialApp(
          title: 'oMsg',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          theme: buildAstraTheme(appearance),
          home: _loading
              ? const _SplashScreen()
              : (_tokens == null || _user == null)
              ? AuthScreen(api: _api, onAuthorized: _onAuthorized)
              : _needsProfileSetup
              ? ProfileSetupScreen(
                  api: _api,
                  getTokens: () => _tokens,
                  user: _user!,
                  onCompleted: _completeProfileSetup,
                  onLogout: _performLogout,
                )
              : HomeShell(
                  api: _api,
                  getTokens: () => _tokens,
                  user: _user!,
                  appVersion: _appVersion,
                  updateChannel: _updateChannel,
                  onUserUpdated: _onUserUpdated,
                  onUpdateChannelChanged: _changeUpdateChannel,
                  onLogout: _performLogout,
                ),
        );
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.send_rounded,
              size: context.sp(52),
              color: Theme.of(context).colorScheme.primary,
            ),
            SizedBox(height: context.sp(14)),
            Text(
              'oMsg',
              style: TextStyle(
                fontSize: context.sp(24),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
