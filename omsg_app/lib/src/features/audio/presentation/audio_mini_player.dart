import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/adaptive_size.dart';
import '../application/chat_audio_playback_controller.dart';

class AudioMiniPlayerBar extends ConsumerWidget {
  final VoidCallback onOpenFullPlayer;

  const AudioMiniPlayerBar({
    super.key,
    required this.onOpenFullPlayer,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(chatAudioPlaybackProvider);
    final current = playback.currentItem;
    if (current == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 6,
      child: InkWell(
        onTap: onOpenFullPlayer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: playback.progress,
              minHeight: 2,
            ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.sp(12),
                vertical: context.sp(8),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: context.sp(18),
                    child: Icon(
                      current.attachment.isVoice
                          ? Icons.mic_rounded
                          : Icons.music_note_rounded,
                      size: context.sp(18),
                    ),
                  ),
                  SizedBox(width: context.sp(10)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          current.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.sp(14),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: context.sp(2)),
                        Text(
                          current.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.sp(12),
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: playback.isPlaying ? 'Pause' : 'Play',
                    onPressed: () async {
                      await playback.togglePlayback();
                    },
                    icon: Icon(
                      playback.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  if (playback.canSkipNext)
                    IconButton(
                      tooltip: 'Next',
                      onPressed: () async {
                        await playback.skipNext();
                      },
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  IconButton(
                    tooltip: 'Close player',
                    onPressed: () async {
                      await playback.stopAndClear();
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
