import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

enum RealtimeState { disconnected, connecting, connected, reconnecting }

class RealtimeMeSocket {
  final String Function() urlBuilder;
  final int? Function()? cursorGetter;
  final void Function(Map<String, dynamic> event) onEvent;
  final void Function(int cursor)? onCursor;
  final void Function(RealtimeState state)? onState;
  final Duration pingInterval;
  final Duration maxReconnectDelay;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _stopped = true;
  int _reconnectAttempt = 0;
  RealtimeState _state = RealtimeState.disconnected;
  int _lastCursor = 0;

  RealtimeMeSocket({
    required this.urlBuilder,
    this.cursorGetter,
    required this.onEvent,
    this.onCursor,
    this.onState,
    this.pingInterval = const Duration(seconds: 20),
    this.maxReconnectDelay = const Duration(seconds: 30),
  });

  bool get isConnected => _state == RealtimeState.connected;

  void start() {
    if (!_stopped) return;
    _stopped = false;
    _connect();
  }

  void stop() {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _setState(RealtimeState.disconnected);
  }

  bool sendJson(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null || !isConnected) return false;
    try {
      channel.sink.add(jsonEncode(payload));
      return true;
    } catch (_) {
      _handleDisconnect();
      return false;
    }
  }

  void _connect() {
    if (_stopped) return;
    final rawUrl = _buildUrlWithCursor(urlBuilder().trim());
    if (rawUrl.isEmpty) {
      _scheduleReconnect();
      return;
    }

    _setState(
      _reconnectAttempt == 0
          ? RealtimeState.connecting
          : RealtimeState.reconnecting,
    );

    try {
      final channel = WebSocketChannel.connect(Uri.parse(rawUrl));
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleIncoming,
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
        cancelOnError: true,
      );
      _reconnectAttempt = 0;
      _setState(RealtimeState.connected);
      _startPing();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _handleIncoming(dynamic event) {
    Map<String, dynamic>? map;
    if (event is String) {
      try {
        final decoded = jsonDecode(event);
        if (decoded is Map) {
          map = decoded.cast<String, dynamic>();
        }
      } catch (_) {
        return;
      }
    } else if (event is Map) {
      map = event.cast<String, dynamic>();
    }

    if (map == null) return;
    _captureCursor(map['cursor']);
    if ((map['type'] ?? '').toString() == 'pong') return;
    onEvent(map);
  }

  String _buildUrlWithCursor(String rawUrl) {
    if (rawUrl.isEmpty) return rawUrl;
    final uri = Uri.parse(rawUrl);
    final configuredCursor = cursorGetter?.call() ?? _lastCursor;
    if (configuredCursor <= 0) return rawUrl;
    final nextQuery = Map<String, String>.from(uri.queryParameters);
    nextQuery['cursor'] = '$configuredCursor';
    return uri.replace(queryParameters: nextQuery).toString();
  }

  void _captureCursor(dynamic rawCursor) {
    final value = switch (rawCursor) {
      int v => v,
      num v => v.toInt(),
      String v => int.tryParse(v) ?? 0,
      _ => 0,
    };
    if (value <= _lastCursor) return;
    _lastCursor = value;
    onCursor?.call(value);
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      sendJson(const {'type': 'ping'});
    });
  }

  void _handleDisconnect() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    if (_stopped) {
      _setState(RealtimeState.disconnected);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    if (_reconnectTimer != null) return;

    _setState(RealtimeState.reconnecting);
    _reconnectAttempt += 1;
    final exponent = math.min(_reconnectAttempt - 1, 5);
    final delaySeconds = math.min(
      maxReconnectDelay.inSeconds,
      math.pow(2, exponent).toInt(),
    );
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _reconnectTimer = null;
      _connect();
    });
  }

  void _setState(RealtimeState next) {
    if (_state == next) return;
    _state = next;
    onState?.call(next);
  }
}
