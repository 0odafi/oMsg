import 'package:flutter/services.dart';

abstract class DeepLinkSource {
  Future<Uri?> getInitialUri();
  Stream<Uri> get uriStream;
}

class NoopDeepLinkSource implements DeepLinkSource {
  const NoopDeepLinkSource();

  @override
  Future<Uri?> getInitialUri() async => null;

  @override
  Stream<Uri> get uriStream => const Stream<Uri>.empty();
}

class PlatformDeepLinkSource implements DeepLinkSource {
  static const MethodChannel _methodChannel = MethodChannel(
    'omsg/deep_links',
  );
  static const EventChannel _eventChannel = EventChannel(
    'omsg/deep_links/events',
  );

  const PlatformDeepLinkSource();

  @override
  Future<Uri?> getInitialUri() async {
    try {
      final raw = await _methodChannel.invokeMethod<String>('getInitialLink');
      if (raw == null || raw.trim().isEmpty) return null;
      return Uri.tryParse(raw.trim());
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<Uri> get uriStream => _eventChannel
      .receiveBroadcastStream()
      .where((event) => event != null)
      .map((event) => Uri.tryParse(event.toString()))
      .where((uri) => uri != null)
      .cast<Uri>();
}
