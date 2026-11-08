import 'package:flutter/material.dart';

import '../../state/models.dart';
import '../../state/player.dart';
import '../../theme.dart';
import '../download_menu.dart';
import '../widgets.dart';
import 'controls.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.p,
    required this.phone,
    required this.onOpen,
    this.onDownload,
    this.onCompact,
  });

  final PlayerState p;
  final bool phone;
  final OpenPage onOpen;
  final Download? onDownload;
  final VoidCallback? onCompact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        if (!p.hasTrack && !p.loading) return const SizedBox.shrink();
        return phone ? _Phone(p: p) : _Desktop(p: p, onOpen: onOpen, onDownload: onDownload, onCompact: onCompact);
      },
    );
  }
}

class _Starting extends StatelessWidget {
  const _Starting();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: context.status.accent),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'Запускаю Мою волну…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _NowTitle extends StatelessWidget {
  const _NowTitle({required this.p, required this.size, this.onOpen});

  final PlayerState p;
  final double size;
  final OpenPage? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = p.track;
    if (t == null) return const _Starting();
    return Semantics(
      button: true,
      label: 'Открыть плеер',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => p.panelOpen.value = true,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Cover(url: t.cover, size: size, radius: 8, kind: ReleaseKind.track),
              const SizedBox(width: 12),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: TrackText(track: t, onOpen: onOpen),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Desktop extends StatelessWidget {
  const _Desktop({required this.p, required this.onOpen, this.onDownload, this.onCompact});

  final PlayerState p;
  final OpenPage onOpen;
  final Download? onDownload;
  final VoidCallback? onCompact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = p.track;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1100;
        final roomy = box.maxWidth >= 820;
        final quality = box.maxWidth >= (onCompact != null ? 900 : 820);
        return Container(
          constraints: const BoxConstraints(minHeight: 80),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: _NowTitle(p: p, size: roomy ? 48 : 40, onOpen: onOpen),
                    ),
                    if (t != null) ...[
                      const SizedBox(width: 4),
                      LikeButton(p: p, track: t),
                      if (p.wave && roomy) DislikeButton(p: p, track: t),
                      if (roomy) TrackMenu(
                          track: t,
                          onOpen: onOpen,
                          onDownload: onDownload,
                          onWave: () => p.playWave(track: t),
                          onShare: p.share,
                        ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: roomy ? 16 : 12),
              SizedBox(
                width: wide ? 440 : (roomy ? 300 : 252),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!p.wave) ShuffleButton(p: p, size: 36),
                        SkipButton(p: p, forward: false),
                        const SizedBox(width: 4),
                        PlayPauseButton(p: p, size: 42),
                        const SizedBox(width: 4),
                        SkipButton(p: p, forward: true),
                        RepeatButton(p: p, size: 36),
                      ],
                    ),
                    SeekBar(p: p, compact: true),
                  ],
                ),
              ),
              SizedBox(width: roomy ? 16 : 12),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (quality) Flexible(child: QualityMenu(p: p)),
                    VolumeControl(p: p),
                    if (onCompact != null)
                      IconButton(
                        tooltip: 'Мини-плеер',
                        onPressed: onCompact,
                        icon: const Icon(Icons.picture_in_picture_alt_rounded),
                      ),
                    IconButton(
                      tooltip: 'Открыть плеер и очередь',
                      onPressed: p.hasTrack ? () => p.panelOpen.value = true : null,
                      icon: const Icon(Icons.queue_music_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Phone extends StatelessWidget {
  const _Phone({required this.p});

  final PlayerState p;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: ListenableBuilder(
              listenable: Listenable.merge([p.position, p.duration]),
              builder: (context, _) {
                final total = p.duration.value.inMilliseconds;
                return LinearProgressIndicator(
                  value: total > 0 ? (p.position.value.inMilliseconds / total).clamp(0.0, 1.0) : 0,
                  minHeight: 2,
                  borderRadius: BorderRadius.zero,
                  color: context.status.accent,
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
            child: Row(
              children: [
                Expanded(child: _NowTitle(p: p, size: 42)),
                SkipButton(p: p, forward: false, size: 44),
                PlayPauseButton(p: p, size: 44),
                SkipButton(p: p, forward: true, size: 44),
              ],
            ),
          ),
          Divider(height: 1, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}
