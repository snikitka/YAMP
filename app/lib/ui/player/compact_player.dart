import 'package:flutter/material.dart';

import '../../state/controller.dart';
import '../../state/models.dart';
import '../../theme.dart';
import '../widgets.dart';
import 'controls.dart';

class CompactPlayer extends StatelessWidget {
  const CompactPlayer({super.key, required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = c.player;
    return Material(
      color: scheme.surfaceContainerLowest,
      shape: Border.all(color: scheme.outlineVariant),
      child: _Resizable(
        onResize: c.desktop.resize,
        child: LayoutBuilder(
          builder: (context, box) => ListenableBuilder(
            listenable: Listenable.merge([p, c.pinned]),
            builder: (context, _) => _body(context, box),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, BoxConstraints box) {
    final scheme = Theme.of(context).colorScheme;
    final p = c.player;
    final t = p.track;
    final pinned = c.pinned.value;
    final volume = (box.maxWidth - 300).clamp(56.0, 160.0);
    const corner = VisualDensity(horizontal: -2, vertical: -2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => c.desktop.drag(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
              child: LayoutBuilder(
                builder: (context, area) {
                  final art = area.maxHeight.clamp(40.0, area.maxWidth * 0.42);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (t != null)
                        Cover(url: t.cover, size: art, radius: 8, kind: ReleaseKind.track)
                      else
                        SizedBox.square(dimension: art),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: t == null
                              ? Text('Ничего не играет', style: TextStyle(color: scheme.onSurfaceVariant))
                              : Semantics(liveRegion: true, child: TrackText(track: t, big: art >= 140)),
                        ),
                      ),
                      IconButton(
                        tooltip: pinned ? 'Открепить от верха' : 'Поверх всех окон',
                        visualDensity: corner,
                        isSelected: pinned,
                        onPressed: c.togglePin,
                        icon: const Icon(Icons.push_pin_outlined, size: 20),
                        selectedIcon: Icon(Icons.push_pin_rounded, size: 20, color: context.status.accent),
                      ),
                      IconButton(
                        tooltip: 'Развернуть окно',
                        visualDensity: corner,
                        onPressed: () => c.setCompact(false),
                        icon: const Icon(Icons.open_in_full_rounded, size: 20),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              if (t != null) LikeButton(p: p, track: t, size: 36) else const SizedBox(width: 36),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SkipButton(p: p, forward: false),
                    const SizedBox(width: 4),
                    PlayPauseButton(p: p, size: 40),
                    const SizedBox(width: 4),
                    SkipButton(p: p, forward: true),
                    if (!p.wave) RepeatButton(p: p, size: 36),
                  ],
                ),
              ),
              VolumeControl(p: p, width: volume),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: SeekBar(p: p, compact: true),
        ),
      ],
    );
  }
}

class _Resizable extends StatelessWidget {
  const _Resizable({required this.child, required this.onResize});

  final Widget child;
  final void Function(String edge) onResize;

  static const _edge = 6.0;
  static const _corner = 14.0;

  Widget _handle(String edge, MouseCursor cursor) => MouseRegion(
    cursor: cursor,
    child: GestureDetector(behavior: HitTestBehavior.translucent, onPanStart: (_) => onResize(edge)),
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: _corner,
          right: _corner,
          top: 0,
          height: _edge,
          child: _handle('top', SystemMouseCursors.resizeUpDown),
        ),
        Positioned(
          left: _corner,
          right: _corner,
          bottom: 0,
          height: _edge,
          child: _handle('bottom', SystemMouseCursors.resizeUpDown),
        ),
        Positioned(
          top: _corner,
          bottom: _corner,
          left: 0,
          width: _edge,
          child: _handle('left', SystemMouseCursors.resizeLeftRight),
        ),
        Positioned(
          top: _corner,
          bottom: _corner,
          right: 0,
          width: _edge,
          child: _handle('right', SystemMouseCursors.resizeLeftRight),
        ),
        Positioned(
          left: 0,
          top: 0,
          width: _corner,
          height: _corner,
          child: _handle('topLeft', SystemMouseCursors.resizeUpLeftDownRight),
        ),
        Positioned(
          right: 0,
          top: 0,
          width: _corner,
          height: _corner,
          child: _handle('topRight', SystemMouseCursors.resizeUpRightDownLeft),
        ),
        Positioned(
          left: 0,
          bottom: 0,
          width: _corner,
          height: _corner,
          child: _handle('bottomLeft', SystemMouseCursors.resizeUpRightDownLeft),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          width: _corner,
          height: _corner,
          child: _handle('bottomRight', SystemMouseCursors.resizeUpLeftDownRight),
        ),
      ],
    );
  }
}
