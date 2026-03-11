import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../models.dart';
import '../../audio/application/chat_audio_playback_controller.dart';

class ChatPhotoViewerPage extends StatelessWidget {
  final MessageAttachmentItem attachment;
  final String imageUrl;

  const ChatPhotoViewerPage({
    super.key,
    required this.attachment,
    required this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final title = attachment.fileName.trim().isEmpty
        ? 'Photo'
        : attachment.fileName.trim();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.75,
                maxScale: 4,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.contain,
                    progressIndicatorBuilder: (context, url, progress) {
                      return Center(
                        child: CircularProgressIndicator(
                          value: progress.progress,
                          color: Colors.white,
                        ),
                      );
                    },
                    errorWidget: (context, url, error) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                        size: 44,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Text(
                    _buildPhotoMeta(attachment),
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildPhotoMeta(MessageAttachmentItem attachment) {
    final parts = <String>[];
    if (attachment.width != null && attachment.height != null) {
      parts.add('${attachment.width}x${attachment.height}');
    }
    parts.add(_formatBytes(attachment.sizeBytes));
    return parts.join(' • ');
  }
}

class ChatVideoViewerPage extends StatefulWidget {
  final MessageAttachmentItem attachment;
  final String videoUrl;

  const ChatVideoViewerPage({
    super.key,
    required this.attachment,
    required this.videoUrl,
  });

  @override
  State<ChatVideoViewerPage> createState() => _ChatVideoViewerPageState();
}

class _ChatVideoViewerPageState extends State<ChatVideoViewerPage> {
  late final VideoPlayerController _controller;
  late final Future<void> _initializeFuture;
  Timer? _overlayHideTimer;
  bool _showChrome = true;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    _initializeFuture = _controller.initialize().then((_) {
      _controller.setLooping(false);
      if (mounted) {
        setState(() {});
      }
    });
    _controller.addListener(_onControllerTick);
    _scheduleChromeAutoHide();
  }

  @override
  void dispose() {
    _overlayHideTimer?.cancel();
    _controller.removeListener(_onControllerTick);
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onControllerTick() {
    if (!mounted) return;
    setState(() {});
  }

  void _togglePlayback() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
    _showChromeTemporarily();
  }

  void _toggleChrome() {
    setState(() => _showChrome = !_showChrome);
    if (_showChrome) {
      _scheduleChromeAutoHide();
    } else {
      _overlayHideTimer?.cancel();
    }
  }

  void _showChromeTemporarily() {
    if (!_showChrome && mounted) {
      setState(() => _showChrome = true);
    }
    _scheduleChromeAutoHide();
  }

  void _scheduleChromeAutoHide() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_controller.value.isPlaying) return;
      setState(() => _showChrome = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const _MediaErrorState(label: 'Could not open video');
          }
          if (snapshot.connectionState != ConnectionState.done ||
              !_controller.value.isInitialized) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }

          final position = _controller.value.position;
          final duration = _controller.value.duration;
          final safeDuration = duration.inMilliseconds <= 0
              ? 1.0
              : duration.inMilliseconds.toDouble();
          final progress =
              (position.inMilliseconds / safeDuration).clamp(0.0, 1.0);

          return GestureDetector(
            onTap: _toggleChrome,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: _showChrome ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: IgnorePointer(
                      ignoring: !_showChrome,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.6),
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.72),
                            ],
                          ),
                        ),
                        child: SafeArea(
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      onPressed: () => Navigator.of(context).pop(),
                                      icon: const Icon(
                                        Icons.arrow_back_rounded,
                                        color: Colors.white,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        widget.attachment.displayLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              Center(
                                child: IconButton.filled(
                                  style: IconButton.styleFrom(
                                    backgroundColor:
                                        Colors.black.withValues(alpha: 0.45),
                                    foregroundColor: Colors.white,
                                    iconSize: 34,
                                    padding: const EdgeInsets.all(16),
                                  ),
                                  onPressed: _togglePlayback,
                                  icon: Icon(
                                    _controller.value.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          _formatDuration(position),
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          _formatDuration(duration),
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                    SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 6,
                                        ),
                                        overlayShape: SliderComponentShape.noOverlay,
                                      ),
                                      child: Slider(
                                        value: progress,
                                        onChanged: (value) {
                                          final target = Duration(
                                            milliseconds: (duration.inMilliseconds * value)
                                                .round(),
                                          );
                                          _controller.seekTo(target);
                                          _showChromeTemporarily();
                                        },
                                      ),
                                    ),
                                    Text(
                                      _buildVideoMeta(widget.attachment),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _buildVideoMeta(MessageAttachmentItem attachment) {
    final parts = <String>[];
    if (attachment.width != null && attachment.height != null) {
      parts.add('${attachment.width}x${attachment.height}');
    }
    if (attachment.durationSeconds != null) {
      parts.add(_formatDuration(Duration(seconds: attachment.durationSeconds!)));
    }
    parts.add(_formatBytes(attachment.sizeBytes));
    return parts.join(' • ');
  }
}

class ChatGalleryEntry {
  final MessageAttachmentItem attachment;
  final String mediaUrl;
  final String previewUrl;

  const ChatGalleryEntry({
    required this.attachment,
    required this.mediaUrl,
    required this.previewUrl,
  });
}

class ChatMediaGalleryPage extends StatefulWidget {
  final List<ChatGalleryEntry> items;
  final int initialIndex;

  const ChatMediaGalleryPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
  });

  @override
  State<ChatMediaGalleryPage> createState() => _ChatMediaGalleryPageState();
}

class _ChatMediaGalleryPageState extends State<ChatMediaGalleryPage> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.items.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_currentIndex];
    final attachment = item.attachment;
    final title = attachment.fileName.trim().isEmpty
        ? 'Media ${_currentIndex + 1}'
        : attachment.fileName.trim();
    final meta = _buildMeta(attachment);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_currentIndex + 1}/${widget.items.length}',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.items.length,
              onPageChanged: (value) {
                setState(() => _currentIndex = value);
              },
              itemBuilder: (context, index) {
                final galleryItem = widget.items[index];
                if (galleryItem.attachment.isVideo) {
                  return _GalleryVideoPage(
                    attachment: galleryItem.attachment,
                    videoUrl: galleryItem.mediaUrl,
                  );
                }
                return InteractiveViewer(
                  minScale: 0.75,
                  maxScale: 4,
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: galleryItem.mediaUrl,
                      fit: BoxFit.contain,
                      progressIndicatorBuilder: (context, url, progress) =>
                          Center(
                            child: CircularProgressIndicator(
                              value: progress.progress,
                              color: Colors.white,
                            ),
                          ),
                      errorWidget: (context, url, error) => const Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white70,
                          size: 44,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Text(
                    meta,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildMeta(MessageAttachmentItem attachment) {
    final parts = <String>[];
    if (attachment.width != null && attachment.height != null) {
      parts.add('${attachment.width}x${attachment.height}');
    }
    if (attachment.durationSeconds != null) {
      parts.add(_formatDuration(Duration(seconds: attachment.durationSeconds!)));
    }
    parts.add(_formatBytes(attachment.sizeBytes));
    return parts.join(' • ');
  }
}

class _GalleryVideoPage extends StatefulWidget {
  final MessageAttachmentItem attachment;
  final String videoUrl;

  const _GalleryVideoPage({
    required this.attachment,
    required this.videoUrl,
  });

  @override
  State<_GalleryVideoPage> createState() => _GalleryVideoPageState();
}

class _GalleryVideoPageState extends State<_GalleryVideoPage> {
  late final VideoPlayerController _controller;
  late final Future<void> _initializeFuture;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    _initializeFuture = _controller.initialize().then((_) {
      _controller.setLooping(false);
      if (mounted) {
        setState(() {});
      }
    });
    _controller.addListener(_onTick);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onTick() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initializeFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _MediaErrorState(label: 'Could not open video');
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !_controller.value.isInitialized) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        final position = _controller.value.position;
        final duration = _controller.value.duration;
        final safeDuration = duration.inMilliseconds <= 0
            ? 1.0
            : duration.inMilliseconds.toDouble();
        final progress = (position.inMilliseconds / safeDuration).clamp(0.0, 1.0);

        return GestureDetector(
          onTap: () {
            if (_controller.value.isPlaying) {
              _controller.pause();
            } else {
              _controller.play();
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: VideoPlayer(_controller),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _controller.value.isPlaying ? 0 : 1,
                      duration: const Duration(milliseconds: 180),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 90,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ChatAudioPlayerPage extends ConsumerStatefulWidget {
  final List<ChatAudioQueueItem>? queue;
  final int? initialIndex;

  const ChatAudioPlayerPage({
    super.key,
    this.queue,
    this.initialIndex,
  });

  @override
  ConsumerState<ChatAudioPlayerPage> createState() =>
      _ChatAudioPlayerPageState();
}

class _ChatAudioPlayerPageState extends ConsumerState<ChatAudioPlayerPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final queue = widget.queue;
      if (queue == null || queue.isEmpty) {
        return;
      }
      final safeIndex = (widget.initialIndex ?? 0)
          .clamp(0, queue.length - 1)
          .toInt();
      final playback = ref.read(chatAudioPlaybackProvider);
      final shouldAutoplay =
          !(playback.sameQueue(queue) &&
              playback.currentIndex == safeIndex &&
              playback.currentItem?.attachment.id ==
                  queue[safeIndex].attachment.id);
      unawaited(
        playback.setQueue(
          queue,
          initialIndex: safeIndex,
          autoPlay: shouldAutoplay,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(chatAudioPlaybackProvider);
    final current = playback.currentItem;
    if (current == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Audio player')),
        body: const Center(
          child: Text('No active audio queue'),
        ),
      );
    }

    final shownDuration = playback.effectiveDuration;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          current.attachment.isVoice ? 'Voice messages' : 'Audio player',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await playback.cyclePlaybackRate();
            },
            child: Text('${playback.playbackRate.toStringAsFixed(playback.playbackRate.truncateToDouble() == playback.playbackRate ? 0 : 2)}x'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Spacer(),
                    CircleAvatar(
                      radius: 56,
                      child: Icon(
                        current.attachment.isVoice
                            ? Icons.mic_rounded
                            : Icons.graphic_eq_rounded,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      current.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      current.subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (playback.errorText != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        playback.errorText!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Text(_formatDuration(playback.position)),
                        const Spacer(),
                        Text(_formatDuration(shownDuration)),
                      ],
                    ),
                    Slider(
                      value: playback.progress,
                      onChanged: (value) async {
                        await playback.seekToFraction(value);
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          onPressed:
                              playback.canSkipPrevious
                                  ? () async {
                                      await playback.skipPrevious();
                                    }
                                  : null,
                          icon: const Icon(Icons.skip_previous_rounded),
                        ),
                        const SizedBox(width: 16),
                        IconButton.filled(
                          style: IconButton.styleFrom(
                            padding: const EdgeInsets.all(18),
                            iconSize: 34,
                          ),
                          onPressed: () async {
                            await playback.togglePlayback();
                          },
                          icon: Icon(
                            playback.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        const SizedBox(width: 16),
                        IconButton.filledTonal(
                          onPressed: playback.canSkipNext
                              ? () async {
                                  await playback.skipNext();
                                }
                              : null,
                          icon: const Icon(Icons.skip_next_rounded),
                        ),
                      ],
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ),
              child: SizedBox(
                height: 220,
                child: ListView.separated(
                  itemCount: playback.queue.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = playback.queue[index];
                    final selected = index == playback.currentIndex;
                    return ListTile(
                      leading: CircleAvatar(
                        child: Icon(
                          item.attachment.isVoice
                              ? Icons.mic_rounded
                              : Icons.music_note_rounded,
                        ),
                      ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        _formatDuration(
                          item.attachment.durationSeconds == null
                              ? Duration.zero
                              : Duration(
                                  seconds: item.attachment.durationSeconds!,
                                ),
                        ),
                      ),
                      selected: selected,
                      onTap: () async {
                        await playback.setQueue(
                          playback.queue,
                          initialIndex: index,
                          autoPlay: true,
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaErrorState extends StatelessWidget {
  final String label;

  const _MediaErrorState({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Colors.white70,
            size: 42,
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
