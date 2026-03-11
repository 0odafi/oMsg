import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models.dart';

final chatAudioPlaybackProvider =
    ChangeNotifierProvider<ChatAudioPlaybackController>(
      (ref) {
        final controller = ChatAudioPlaybackController();
        ref.onDispose(controller.dispose);
        return controller;
      },
    );

class ChatAudioQueueItem {
  final MessageAttachmentItem attachment;
  final String audioUrl;
  final String title;
  final String subtitle;

  const ChatAudioQueueItem({
    required this.attachment,
    required this.audioUrl,
    required this.title,
    required this.subtitle,
  });
}

class ChatAudioPlaybackController extends ChangeNotifier {
  ChatAudioPlaybackController({AudioPlayer? player})
    : _player = player ?? AudioPlayer() {
    _bindPlayer();
  }

  final AudioPlayer _player;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<void>? _playerCompleteSubscription;

  List<ChatAudioQueueItem> _queue = const [];
  int _currentIndex = -1;
  PlayerState _playerState = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _playbackRate = 1.0;
  String? _errorText;
  bool _disposed = false;

  List<ChatAudioQueueItem> get queue => _queue;
  int get currentIndex => _currentIndex;
  PlayerState get playerState => _playerState;
  Duration get position => _position;
  Duration get rawDuration => _duration;
  double get playbackRate => _playbackRate;
  String? get errorText => _errorText;

  bool get hasQueue => _queue.isNotEmpty && _currentIndex >= 0;
  bool get isPlaying => _playerState == PlayerState.playing;
  bool get isPaused => _playerState == PlayerState.paused;
  bool get isCompleted => _playerState == PlayerState.completed;
  bool get canSkipPrevious => _currentIndex > 0;
  bool get canSkipNext => hasQueue && _currentIndex < _queue.length - 1;

  ChatAudioQueueItem? get currentItem {
    if (!hasQueue || _currentIndex >= _queue.length) {
      return null;
    }
    return _queue[_currentIndex];
  }

  Duration get effectiveDuration {
    if (_duration.inMilliseconds > 0) {
      return _duration;
    }
    final seconds = currentItem?.attachment.durationSeconds;
    if (seconds == null || seconds <= 0) {
      return Duration.zero;
    }
    return Duration(seconds: seconds);
  }

  double get progress {
    final total = effectiveDuration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  bool isCurrentAttachment(int attachmentId) {
    return currentItem?.attachment.id == attachmentId;
  }

  bool isPlayingAttachment(int attachmentId) {
    return isCurrentAttachment(attachmentId) && isPlaying;
  }

  bool isPausedAttachment(int attachmentId) {
    return isCurrentAttachment(attachmentId) && isPaused;
  }

  bool sameQueue(List<ChatAudioQueueItem> other) {
    return _sameQueue(_queue, other);
  }

  Future<void> setQueue(
    List<ChatAudioQueueItem> queue, {
    int initialIndex = 0,
    bool autoPlay = true,
    bool forceRestart = false,
  }) async {
    if (queue.isEmpty) {
      await stopAndClear();
      return;
    }

    final nextIndex = initialIndex.clamp(0, queue.length - 1).toInt();
    final targetItem = queue[nextIndex];
    final queueMatches = _sameQueue(_queue, queue);
    final sameSelection =
        queueMatches && currentItem?.attachment.id == targetItem.attachment.id;

    _queue = List<ChatAudioQueueItem>.unmodifiable(queue);
    _currentIndex = nextIndex;
    _errorText = null;

    if (!sameSelection || forceRestart) {
      _position = Duration.zero;
      _duration = _fallbackDurationFor(targetItem);
      notifyListeners();
      if (autoPlay) {
        await _playCurrent(resetPosition: true);
      } else {
        notifyListeners();
      }
      return;
    }

    notifyListeners();
    if (!autoPlay) {
      return;
    }
    if (isPaused) {
      await _player.resume();
      return;
    }
    if (isCompleted) {
      await _player.seek(Duration.zero);
      await _playCurrent(resetPosition: true);
      return;
    }
    if (!isPlaying) {
      await _playCurrent(resetPosition: false);
    }
  }

  Future<void> playSingle(
    ChatAudioQueueItem item, {
    bool forceRestart = false,
  }) {
    return setQueue(
      [item],
      initialIndex: 0,
      autoPlay: true,
      forceRestart: forceRestart,
    );
  }

  Future<void> toggleQueueItem(
    List<ChatAudioQueueItem> queue,
    int index,
  ) async {
    if (queue.isEmpty) return;
    final safeIndex = index.clamp(0, queue.length - 1).toInt();
    final target = queue[safeIndex];
    if (isCurrentAttachment(target.attachment.id) && sameQueue(queue)) {
      await togglePlayback();
      return;
    }
    await setQueue(queue, initialIndex: safeIndex, autoPlay: true);
  }

  Future<void> togglePlayback() async {
    if (!hasQueue) return;
    if (isPlaying) {
      await _player.pause();
      return;
    }
    if (isPaused) {
      await _player.resume();
      return;
    }
    if (isCompleted) {
      await _player.seek(Duration.zero);
    }
    await _playCurrent(resetPosition: isCompleted);
  }

  Future<void> seekToFraction(double fraction) async {
    final duration = effectiveDuration;
    if (duration.inMilliseconds <= 0) return;
    final clamped = fraction.clamp(0.0, 1.0);
    final target = Duration(
      milliseconds: (duration.inMilliseconds * clamped).round(),
    );
    await _player.seek(target);
  }

  Future<void> skipPrevious() => _advance(-1, autoPlay: true);

  Future<void> skipNext() => _advance(1, autoPlay: true);

  Future<void> cyclePlaybackRate() async {
    const supportedRates = <double>[1.0, 1.25, 1.5, 2.0];
    final index = supportedRates.indexOf(_playbackRate);
    final next = supportedRates[(index + 1) % supportedRates.length];
    await _player.setPlaybackRate(next);
    _playbackRate = next;
    notifyListeners();
  }

  Future<void> stopAndClear() async {
    _queue = const [];
    _currentIndex = -1;
    _position = Duration.zero;
    _duration = Duration.zero;
    _errorText = null;
    try {
      await _player.stop();
    } catch (_) {}
    _playerState = PlayerState.stopped;
    notifyListeners();
  }

  Future<void> _advance(int direction, {bool autoPlay = false}) async {
    if (!hasQueue) return;
    final nextIndex = (_currentIndex + direction)
        .clamp(0, _queue.length - 1)
        .toInt();
    if (nextIndex == _currentIndex) {
      if (direction < 0) {
        await _player.seek(Duration.zero);
      }
      return;
    }
    _currentIndex = nextIndex;
    _position = Duration.zero;
    _duration = _fallbackDurationFor(_queue[nextIndex]);
    _errorText = null;
    notifyListeners();
    if (autoPlay) {
      await _playCurrent(resetPosition: true);
    }
  }

  Future<void> _playCurrent({required bool resetPosition}) async {
    final item = currentItem;
    if (item == null) return;
    try {
      if (resetPosition) {
        _position = Duration.zero;
        _duration = _fallbackDurationFor(item);
        notifyListeners();
      }
      await _player.play(UrlSource(item.audioUrl));
    } catch (_) {
      _errorText = 'Could not play audio attachment';
      notifyListeners();
    }
  }

  void _bindPlayer() {
    _playerStateSubscription = _player.onPlayerStateChanged.listen((state) {
      _playerState = state;
      notifyListeners();
    });
    _positionSubscription = _player.onPositionChanged.listen((position) {
      _position = position;
      notifyListeners();
    });
    _durationSubscription = _player.onDurationChanged.listen((duration) {
      _duration = duration;
      notifyListeners();
    });
    _playerCompleteSubscription = _player.onPlayerComplete.listen((_) {
      unawaited(_advance(1, autoPlay: true));
    });
  }

  Duration _fallbackDurationFor(ChatAudioQueueItem item) {
    final seconds = item.attachment.durationSeconds;
    if (seconds == null || seconds <= 0) {
      return Duration.zero;
    }
    return Duration(seconds: seconds);
  }

  bool _sameQueue(
    List<ChatAudioQueueItem> left,
    List<ChatAudioQueueItem> right,
  ) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index].attachment.id != right[index].attachment.id ||
          left[index].audioUrl != right[index].audioUrl) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    if (_disposed) {
      super.dispose();
      return;
    }
    _disposed = true;
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }
}
