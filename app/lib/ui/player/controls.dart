import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/player.dart';
import '../../theme.dart';
import '../download_menu.dart';
import '../widgets.dart';

String fmtTime(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

String fmtTotal(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h > 0) return '$h ч $m мин';
  return '${d.inMinutes} мин';
}

String tracksCount(int n) {
  final mod10 = n % 10, mod100 = n % 100;
  final word = mod10 == 1 && mod100 != 11
      ? 'трек'
      : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14) ? 'трека' : 'треков');
  return '$n $word';
}

const tabular = [FontFeature.tabularFigures()];

class ToggleButton extends StatelessWidget {
  const ToggleButton({
    super.key,
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.onPressed,
    this.size = 40,
  });

  final bool selected;
  final IconData icon, selectedIcon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      onPressed: onPressed,
      iconSize: size * 0.55,
      style: IconButton.styleFrom(
        fixedSize: Size.square(size),
        minimumSize: Size.square(size),
        padding: EdgeInsets.zero,
        foregroundColor: selected ? context.status.accent : scheme.onSurfaceVariant,
        backgroundColor: selected ? scheme.primaryContainer : null,
      ),
      icon: Icon(icon),
      selectedIcon: Icon(selectedIcon),
    );
  }
}

class LikeButton extends StatelessWidget {
  const LikeButton({super.key, required this.p, required this.track, this.size = 40});

  final PlayerState p;
  final PlayTrack track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final on = p.liked(track);
    return ToggleButton(
      selected: on,
      size: size,
      icon: Icons.favorite_border_rounded,
      selectedIcon: Icons.favorite_rounded,
      tooltip: on ? 'Убрать из «Мне нравится»' : 'Мне нравится',
      onPressed: () => p.like(track, !on),
    );
  }
}

class DislikeButton extends StatelessWidget {
  const DislikeButton({super.key, required this.p, required this.track, this.size = 40});

  final PlayerState p;
  final PlayTrack track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final on = p.disliked(track);
    return ToggleButton(
      selected: on,
      size: size,
      icon: Icons.thumb_down_off_alt_rounded,
      selectedIcon: Icons.thumb_down_alt_rounded,
      tooltip: on ? 'Снова рекомендовать' : 'Не рекомендовать',
      onPressed: () => p.dislike(track, !on),
    );
  }
}

class RepeatButton extends StatelessWidget {
  const RepeatButton({super.key, required this.p, this.size = 40});

  final PlayerState p;
  final double size;

  @override
  Widget build(BuildContext context) {
    final r = p.repeat;
    return ToggleButton(
      selected: r != Repeat.off,
      size: size,
      icon: Icons.repeat_rounded,
      selectedIcon: r == Repeat.one ? Icons.repeat_one_on_rounded : Icons.repeat_on_rounded,
      tooltip: switch (r) {
        Repeat.off => 'Повтор выключен',
        Repeat.all => 'Повтор всех треков',
        Repeat.one => 'Повтор одного трека',
      },
      onPressed: p.hasTrack ? p.cycleRepeat : null,
    );
  }
}

class ShuffleButton extends StatelessWidget {
  const ShuffleButton({super.key, required this.p, this.size = 40});

  final PlayerState p;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ToggleButton(
      selected: p.shuffle,
      size: size,
      icon: Icons.shuffle_rounded,
      selectedIcon: Icons.shuffle_on_rounded,
      tooltip: p.shuffle ? 'Перемешивание включено' : 'Перемешать',
      onPressed: p.toggleShuffle,
    );
  }
}

class PlayPauseButton extends StatelessWidget {
  const PlayPauseButton({super.key, required this.p, this.size = 40});

  final PlayerState p;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = p.loading || (p.buffering && p.playing);
    final label = p.playing ? 'Пауза' : 'Слушать';
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton.filled(
          tooltip: label,
          onPressed: p.loading && !p.hasTrack ? null : p.togglePlay,
          iconSize: size * 0.55,
          style: IconButton.styleFrom(
            fixedSize: Size.square(size),
            minimumSize: Size.square(size),
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
          ),
          icon: AnimatedSwitcher(
            duration: motion(context, const Duration(milliseconds: 300)),
            switchInCurve: const Cubic(0.2, 0, 0, 1),
            switchOutCurve: const Cubic(0.2, 0, 0, 1),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: Tween(begin: 0.25, end: 1.0).animate(anim), child: child),
            ),
            child: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(p.playing)),
          ),
        ),
        if (busy)
          IgnorePointer(
            child: SizedBox.square(
              dimension: size + 6,
              child: CircularProgressIndicator(strokeWidth: 2, color: context.status.accent),
            ),
          ),
      ],
    );
  }
}

class SkipButton extends StatelessWidget {
  const SkipButton({super.key, required this.p, required this.forward, this.size = 40});

  final PlayerState p;
  final bool forward;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: forward ? 'Следующий трек' : 'Предыдущий трек',
      onPressed: p.hasTrack ? (forward ? p.nextTrack : p.previousTrack) : null,
      iconSize: size * 0.6,
      style: IconButton.styleFrom(
        fixedSize: Size.square(size),
        minimumSize: Size.square(size),
        padding: EdgeInsets.zero,
      ),
      icon: Icon(forward ? Icons.skip_next_rounded : Icons.skip_previous_rounded),
    );
  }
}

class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.p, this.compact = false});

  final PlayerState p;
  final bool compact;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag;

  PlayerState get p => widget.p;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontFeatures: tabular);
    return ListenableBuilder(
      listenable: Listenable.merge([p.position, p.duration]),
      builder: (context, _) {
        final total = p.duration.value;
        final max = total.inMilliseconds > 0 ? total.inMilliseconds / 1000 : 1.0;
        final now = (_drag ?? p.position.value.inMilliseconds / 1000).clamp(0.0, max);
        final at = Duration(milliseconds: (now * 1000).round());
        final slider = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            tickMarkShape: SliderTickMarkShape.noTickMark,
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Slider(
            value: now,
            max: max,
            semanticFormatterCallback: (v) => '${fmtTime(Duration(seconds: v.round()))} из ${fmtTime(total)}',
            onChanged: p.hasTrack && total > Duration.zero ? (v) => setState(() => _drag = v) : null,
            onChangeEnd: (v) {
              setState(() => _drag = null);
              p.seek(Duration(milliseconds: (v * 1000).round()));
            },
          ),
        );
        return Semantics(
          label: 'Позиция в треке',
          child: Row(
            children: [
              ExcludeSemantics(
                child: SizedBox(
                  width: 40,
                  child: Text(fmtTime(at), style: time, textAlign: TextAlign.end),
                ),
              ),
              Expanded(child: slider),
              ExcludeSemantics(
                child: SizedBox(width: 40, child: Text(fmtTime(total), style: time)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class VolumeControl extends StatefulWidget {
  const VolumeControl({super.key, required this.p, this.width});

  final PlayerState p;
  final double? width;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  final _portal = OverlayPortalController();
  final _anchor = GlobalKey();
  Timer? _hide;
  Timer? _commit;
  var _overButton = false;
  var _overPopup = false;
  var _focused = false;
  var _dragging = false;
  var _touch = false;

  PlayerState get p => widget.p;

  static const _step = 0.05;

  void _show() {
    _hide?.cancel();
    if (!_portal.isShowing) _portal.show();
  }

  void _leave() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 240), () {
      if (!mounted || _dragging || _focused || _overButton || _overPopup || !_portal.isShowing) return;
      _portal.hide();
    });
  }

  void _close() {
    _hide?.cancel();
    if (_portal.isShowing) _portal.hide();
  }

  void _nudge(int steps) {
    p.previewVolume(((p.volume + steps * _step) / _step).round() * _step);
    _commit?.cancel();
    _commit = Timer(const Duration(milliseconds: 400), p.commitVolume);
  }

  void _scroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (e) {
      final dy = (e as PointerScrollEvent).scrollDelta.dy;
      if (dy == 0) return;
      _nudge(dy < 0 ? 1 : -1);
      if (widget.width == null) _show();
    });
  }

  void _pressed() {
    if (!_touch) {
      p.toggleMute();
    } else if (_portal.isShowing) {
      _close();
    } else {
      _show();
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    if (_commit?.isActive ?? false) {
      _commit!.cancel();
      p.commitVolume();
    }
    super.dispose();
  }

  Widget _slider(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.never,
      ),
      child: Slider(
        value: p.volume,
        divisions: 20,
        semanticFormatterCallback: (x) => 'Громкость ${(x * 100).round()}%',
        onChangeStart: (_) => _dragging = true,
        onChanged: p.previewVolume,
        onChangeEnd: (_) {
          _dragging = false;
          p.commitVolume();
          _leave();
        },
      ),
    );
  }

  Widget _inline(BuildContext context, double width) {
    final v = p.volume;
    return Listener(
      onPointerSignal: _scroll,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: v == 0 ? 'Включить звук' : 'Выключить звук',
            onPressed: p.toggleMute,
            icon: Icon(
              v == 0 ? Icons.volume_off_rounded : (v < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
            ),
          ),
          SizedBox(width: width, child: _slider(context)),
        ],
      ),
    );
  }

  Widget _popup(BuildContext context) {
    final anchor = _anchor.currentContext?.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (anchor is! RenderBox || overlay is! RenderBox || !anchor.attached || !anchor.hasSize) {
      return const SizedBox.shrink();
    }
    final rect = MatrixUtils.transformRect(anchor.getTransformTo(overlay), Offset.zero & anchor.size);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return CustomSingleChildLayout(
      delegate: _PopupLayout(rect),
      child: TapRegion(
        groupId: this,
        onTapOutside: (_) => _close(),
        child: MouseRegion(
          onEnter: (_) {
            _overPopup = true;
            _show();
          },
          onExit: (_) {
            _overPopup = false;
            _leave();
          },
          child: Listener(
            onPointerSignal: _scroll,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Material(
                color: theme.popupMenuTheme.color ?? theme.colorScheme.surfaceContainerHigh,
                elevation: 6,
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 44,
                  child: ListenableBuilder(
                    listenable: p,
                    builder: (context, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 10),
                        Text(
                          '${(p.volume * 100).round()}',
                          style: TextStyle(fontSize: 12, color: muted, fontFeatures: tabular),
                        ),
                        Flexible(
                          child: SizedBox(
                            height: 124,
                            child: RotatedBox(quarterTurns: 3, child: _slider(context)),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    if (width != null) return _inline(context, width);
    final v = p.volume;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _popup,
      child: TapRegion(
        groupId: this,
        child: Semantics(
          container: true,
          label: 'Громкость',
          value: '${(v * 100).round()}%',
          increasedValue: '${((v + _step).clamp(0.0, 1.0) * 100).round()}%',
          decreasedValue: '${((v - _step).clamp(0.0, 1.0) * 100).round()}%',
          onIncrease: () => _nudge(1),
          onDecrease: () => _nudge(-1),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowUp): () => _nudge(1),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () => _nudge(-1),
            },
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (focused) {
                _focused = focused;
                focused ? _show() : _leave();
              },
              child: MouseRegion(
                onEnter: (_) {
                  _overButton = true;
                  _show();
                },
                onExit: (_) {
                  _overButton = false;
                  _leave();
                },
                child: Listener(
                  onPointerDown: (e) => _touch = e.kind == PointerDeviceKind.touch,
                  onPointerSignal: _scroll,
                  child: IconButton(
                    key: _anchor,
                    onPressed: _pressed,
                    icon: Icon(
                      v == 0 ? Icons.volume_off_rounded : (v < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                      semanticLabel: v == 0 ? 'Включить звук' : 'Выключить звук',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PopupLayout extends SingleChildLayoutDelegate {
  _PopupLayout(this.anchor);

  final Rect anchor;

  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final room = math.max(anchor.top, constraints.maxHeight - anchor.bottom) - _margin;
    return BoxConstraints(maxWidth: constraints.maxWidth, maxHeight: math.max(room, 0));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = size.height - anchor.bottom;
    final above = anchor.top - _margin >= childSize.height || anchor.top >= below;
    final x = (anchor.center.dx - childSize.width / 2).clamp(_margin, math.max(_margin, size.width - childSize.width - _margin)).toDouble();
    return Offset(x, above ? anchor.top - childSize.height : anchor.bottom);
  }

  @override
  bool shouldRelayout(_PopupLayout oldDelegate) => oldDelegate.anchor != anchor;
}

String qualityLabel(PlayQuality q) => switch (q) {
  PlayQuality.lossless => 'FLAC (без потерь)',
  PlayQuality.mp3 => 'MP3 320',
  PlayQuality.low => 'Экономия трафика',
};

class QualityMenu extends StatelessWidget {
  const QualityMenu({super.key, required this.p});

  final PlayerState p;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = p.format.isNotEmpty
        ? p.format
        : switch (p.quality) {
            PlayQuality.lossless => 'FLAC',
            PlayQuality.mp3 => 'MP3 320',
            PlayQuality.low => 'Эконом',
          };
    return MenuAnchor(
      alignmentOffset: const Offset(0, -4),
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(p.autoQuality ? Icons.check_rounded : null),
          onPressed: p.setAutoQuality,
          child: const Text('Авто: по типу сети'),
        ),
        const Divider(height: 8),
        for (final q in PlayQuality.values)
          MenuItemButton(
            leadingIcon: Icon(!p.autoQuality && p.quality == q ? Icons.check_rounded : null),
            onPressed: () => p.setQuality(q),
            child: Text(qualityLabel(q)),
          ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: p.autoQuality ? 'Качество: авто, сейчас ${qualityLabel(p.quality)}' : 'Качество: ${qualityLabel(p.quality)}',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tag(shown, icon: Icons.graphic_eq_rounded, color: context.status.accent),
                Icon(Icons.expand_more_rounded, size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef OpenPage = void Function(String source);

class LinkPart {
  const LinkPart(this.text, [this.source = '']);

  final String text, source;
}

List<LinkPart> artistParts(List<PlayArtist> artists, String fallback, {String here = ''}) {
  if (artists.isEmpty) return [LinkPart(fallback)];
  return [
    for (var i = 0; i < artists.length; i++) ...[
      if (i > 0) const LinkPart(', '),
      LinkPart(artists[i].name, artists[i].source == here ? '' : artists[i].source),
    ],
  ];
}

class LinkText extends StatefulWidget {
  const LinkText({
    super.key,
    required this.parts,
    required this.onOpen,
    this.style,
    this.maxLines = 1,
    this.textAlign = TextAlign.start,
  });

  final List<LinkPart> parts;
  final OpenPage? onOpen;
  final TextStyle? style;
  final int maxLines;
  final TextAlign textAlign;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final _taps = <int, TapGestureRecognizer>{};
  int? _hover;

  @override
  void dispose() {
    for (final t in _taps.values) {
      t.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(int i, String source) =>
      (_taps[i] ??= TapGestureRecognizer())..onTap = () => widget.onOpen?.call(source);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final open = widget.onOpen;
    final parts = widget.parts;
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < parts.length; i++)
            if (open == null || parts[i].source.isEmpty)
              TextSpan(text: parts[i].text)
            else
              TextSpan(
                text: parts[i].text,
                recognizer: _tap(i, parts[i].source),
                mouseCursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hover = i),
                onExit: (_) => setState(() => _hover = _hover == i ? null : _hover),
                style: _hover == i
                    ? TextStyle(
                        color: scheme.onSurface,
                        decoration: TextDecoration.underline,
                        decorationColor: scheme.onSurface,
                      )
                    : null,
              ),
        ],
      ),
      maxLines: widget.maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: widget.textAlign,
      style: widget.style,
    );
  }
}

List<Widget> pageItems(PlayTrack t, OpenPage onOpen, {String here = ''}) => [
  if (t.albumSource.isNotEmpty && t.albumSource != here)
    MenuItemButton(
      leadingIcon: const Icon(Icons.album_rounded),
      onPressed: () => onOpen(t.albumSource),
      child: const Text('Перейти к альбому'),
    ),
  for (final a in t.artists)
    if (a.source != here)
      MenuItemButton(
        leadingIcon: const Icon(Icons.person_rounded),
        onPressed: () => onOpen(a.source),
        child: Text(t.artists.length == 1 ? 'Перейти к исполнителю' : a.name),
      ),
];

const waveByTrack = 'Моя волна по треку';

List<Widget> shareItems(PlayTrack t, void Function(String link) share) => [
  if (t.link.isNotEmpty)
    MenuItemButton(
      leadingIcon: const Icon(Icons.share_outlined),
      onPressed: () => share(t.link),
      child: const Text('Поделиться треком'),
    ),
  if (t.albumSource.isNotEmpty)
    MenuItemButton(
      leadingIcon: const Icon(Icons.album_outlined),
      onPressed: () => share(t.albumSource),
      child: const Text('Поделиться альбомом'),
    ),
];

class TrackMenu extends StatelessWidget {
  const TrackMenu({
    super.key,
    required this.track,
    required this.onOpen,
    this.onDownload,
    this.onWave,
    this.onShare,
    this.size,
    this.onImage = false,
  });

  final PlayTrack track;
  final OpenPage onOpen;
  final Download? onDownload;
  final VoidCallback? onWave;
  final void Function(String link)? onShare;
  final double? size;
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    final pages = pageItems(track, onOpen);
    final downloads = onDownload == null ? const <Widget>[] : downloadItems(onDownload!, track.link, track.title);
    final wave = onWave;
    final shares = onShare == null ? const <Widget>[] : shareItems(track, onShare!);
    if (pages.isEmpty && downloads.isEmpty && wave == null && shares.isEmpty) return const SizedBox.shrink();
    final box = size;
    return MenuAnchor(
      menuChildren: [
        if (wave != null) ...[
          MenuItemButton(leadingIcon: const Icon(Icons.waves_rounded), onPressed: wave, child: const Text(waveByTrack)),
          if (downloads.isNotEmpty || pages.isNotEmpty) const Divider(height: 8),
        ],
        ...downloads,
        if (downloads.isNotEmpty && pages.isNotEmpty) const Divider(height: 8),
        ...pages,
        if (shares.isNotEmpty && (pages.isNotEmpty || downloads.isNotEmpty || wave != null)) const Divider(height: 8),
        ...shares,
      ],
      builder: (context, menu, _) => IconButton(
        tooltip: 'Ещё',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        style: IconButton.styleFrom(
          fixedSize: box == null ? null : Size.square(box),
          minimumSize: box == null ? null : Size.square(box),
          backgroundColor: onImage ? Colors.black.withValues(alpha: 0.28) : null,
        ),
        icon: const Icon(Icons.more_vert_rounded),
      ),
    );
  }
}

class TrackText extends StatelessWidget {
  const TrackText({
    super.key,
    required this.track,
    this.big = false,
    this.center = false,
    this.accent = false,
    this.artistsOnly = false,
    this.onOpen,
  });

  final PlayTrack track;
  final bool big, center, accent, artistsOnly;
  final OpenPage? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final align = center ? TextAlign.center : TextAlign.start;
    return Column(
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: onOpen != null && !artistsOnly && track.album.isNotEmpty
              ? '${track.title}\nАльбом: ${track.album}'
              : track.title,
          child: LinkText(
            parts: [LinkPart(track.title, track.albumSource)],
            onOpen: artistsOnly ? null : onOpen,
            maxLines: big ? 2 : 1,
            textAlign: align,
            style: big
                ? text.titleLarge?.copyWith(height: 1.25)
                : TextStyle(fontWeight: FontWeight.w600, height: 1.3, color: accent ? context.status.accent : null),
          ),
        ),
        const SizedBox(height: 2),
        LinkText(
          parts: artistParts(track.artists, track.artist),
          onOpen: onOpen,
          textAlign: align,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: big ? 15 : 13, height: 1.3),
        ),
      ],
    );
  }
}
