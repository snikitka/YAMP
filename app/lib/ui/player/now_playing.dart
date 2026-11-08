import 'package:flutter/material.dart';

import '../../state/models.dart';
import '../../state/player.dart';
import '../../theme.dart';
import '../download_menu.dart';
import '../widgets.dart';
import 'controls.dart';
import 'lyrics_view.dart';
import 'tint.dart';

const _rowExtent = 56.0;
const _wideFrom = 900.0;

class NowPlaying extends StatelessWidget {
  const NowPlaying({
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

  void _openQueue(BuildContext context) {
    final d = motion(context, const Duration(milliseconds: 260));
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть очередь',
      barrierColor: Colors.black54,
      transitionDuration: d,
      pageBuilder: (context, _, _) => _QueueFlyout(
        p: p,
        onOpen: phone
            ? null
            : (source) {
                Navigator.of(context).pop();
                onOpen(source);
              },
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: const Cubic(0.2, 0, 0, 1))),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: playerTheme,
      child: ListenableBuilder(
        listenable: Listenable.merge([p, p.lyricsOpen]),
        builder: (context, _) {
          final t = p.track;
          final lyrics = p.lyricsOpen.value;
          return PlayerBackdrop(
            url: t?.cover ?? '',
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final wide = !phone && box.maxWidth >= _wideFrom;
                  final side = phone ? 16.0 : 24.0;
                  if (t == null) {
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: side),
                      child: Column(
                        children: [
                          _Header(p: p, onOpen: onOpen),
                          const Expanded(child: Center(child: CircularProgressIndicator())),
                        ],
                      ),
                    );
                  }
                  final compact = onCompact == null || phone
                      ? null
                      : IconButton(
                          tooltip: 'Мини-плеер',
                          icon: const Icon(Icons.picture_in_picture_alt_rounded),
                          onPressed: onCompact,
                        );
                  final menu = TrackMenu(
                    track: t,
                    onOpen: onOpen,
                    onDownload: onDownload,
                    onWave: () => p.playWave(track: t),
                    onShare: p.share,
                    size: 44,
                  );
                  if (wide) {
                    final trailing = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ViewSwitch(p: p, track: t),
                        if (compact != null) ...[
                          const SizedBox(width: 4),
                          compact,
                        ],
                      ],
                    );
                    final edge = onCompact != null ? 164.0 : 112.0;
                    return lyrics
                        ? _WideLyrics(
                            p: p,
                            track: t,
                            box: box,
                            onOpen: onOpen,
                            menu: menu,
                            trailing: trailing,
                            edge: edge,
                          )
                        : _WideCover(
                            p: p,
                            track: t,
                            box: box,
                            onOpen: onOpen,
                            menu: menu,
                            trailing: trailing,
                            edge: edge,
                          );
                  }
                  if (lyrics) return _NarrowLyrics(p: p, track: t, phone: phone, onOpen: onOpen, compact: compact);
                  return SingleChildScrollView(
                    padding: EdgeInsets.symmetric(horizontal: phone ? 0 : side),
                    child: _NarrowCover(
                      p: p,
                      track: t,
                      phone: phone,
                      side: side,
                      onOpen: onOpen,
                      menu: menu,
                      onQueue: () => _openQueue(context),
                      compact: compact,
                      minHeight: phone ? box.maxHeight : 0,
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

void _close(PlayerState p) => p.panelOpen.value = false;

class _Header extends StatelessWidget {
  const _Header({required this.p, required this.onOpen, this.trailing, this.edge = 48, this.onImage = false});

  final PlayerState p;
  final OpenPage onOpen;
  final Widget? trailing;
  final double edge;
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final from = p.source;
    final source = from?.title ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: edge,
            child: Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Свернуть плеер',
                style: onImage ? IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: 0.28)) : null,
                icon: const Icon(Icons.expand_more_rounded),
                onPressed: () => _close(p),
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Semantics(
                  header: true,
                  child: Text('Сейчас играет', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (source.isNotEmpty)
                  Tooltip(
                    message: from!.browsable ? 'Открыть «$source»' : source,
                    child: LinkText(
                      parts: [LinkPart(source, from.browsable ? from.id : '')],
                      onOpen: onOpen,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: edge,
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ],
      ),
    );
  }
}

class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.p, required this.track, this.labels = false});

  final PlayerState p;
  final PlayTrack track;
  final bool labels;

  @override
  Widget build(BuildContext context) {
    final lyrics = p.lyricsOpen.value;
    Widget part(bool forLyrics) {
      final selected = forLyrics == lyrics;
      final enabled = selected || !forLyrics || track.hasLyrics;
      final label = forLyrics ? 'Текст' : 'Обложка';
      final icon = forLyrics ? Icons.lyrics_rounded : Icons.album_rounded;
      final style = TextButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white.withValues(alpha: 0.38),
        backgroundColor: selected ? Colors.white.withValues(alpha: 0.18) : null,
        minimumSize: Size(labels ? 0 : 44, 40),
        padding: EdgeInsets.symmetric(horizontal: labels ? 12 : 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
      );
      final onPressed = enabled ? () => p.lyricsOpen.value = forLyrics : null;
      final button = labels
          ? TextButton(onPressed: onPressed, style: style, child: Text(label))
          : TextButton(onPressed: onPressed, style: style, child: Icon(icon, size: 20));
      final tip = Semantics(
        selected: selected,
        child: Tooltip(
          message: forLyrics ? (track.hasLyrics ? 'Текст песни' : 'У трека нет текста') : 'Обложка и очередь',
          child: button,
        ),
      );
      return labels ? Expanded(child: tip) : tip;
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisSize: labels ? MainAxisSize.max : MainAxisSize.min,
        children: [part(false), const SizedBox(width: 4), part(true)],
      ),
    );
  }
}

class _BigCover extends StatelessWidget {
  const _BigCover({required this.p, required this.track, required this.size});

  final PlayerState p;
  final PlayTrack track;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 60, offset: Offset(0, 24))],
        ),
        child: Cover(
          url: p.art.isNotEmpty ? p.art : track.cover,
          size: size,
          radius: 20,
          kind: ReleaseKind.track,
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.p, required this.track, required this.onOpen, this.menu});

  final PlayerState p;
  final PlayTrack track;
  final OpenPage onOpen;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: TrackText(track: track, big: true, onOpen: onOpen),
          ),
        ),
        if (p.wave) DislikeButton(p: p, track: track, size: 44),
        LikeButton(p: p, track: track, size: 44),
        ?menu,
      ],
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.p, this.play = 72, this.skip = 52, this.toggle = 44, this.maxWidth = 380});

  final PlayerState p;
  final double play, skip, toggle, maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (p.wave) SizedBox(width: toggle) else ShuffleButton(p: p, size: toggle),
            SkipButton(p: p, forward: false, size: skip),
            PlayPauseButton(p: p, size: play),
            SkipButton(p: p, forward: true, size: skip),
            RepeatButton(p: p, size: toggle),
          ],
        ),
      ),
    );
  }
}

class _AlbumChip extends StatelessWidget {
  const _AlbumChip({required this.track, required this.onOpen});

  final PlayTrack track;
  final OpenPage onOpen;

  @override
  Widget build(BuildContext context) {
    if (track.album.isEmpty || track.albumSource.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: 'Открыть альбом «${track.album}»',
      child: Material(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onOpen(track.albumSource),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.album_rounded, size: 16),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(track.album, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WideCover extends StatelessWidget {
  const _WideCover({
    required this.p,
    required this.track,
    required this.box,
    required this.onOpen,
    required this.menu,
    required this.trailing,
    required this.edge,
  });

  final PlayerState p;
  final PlayTrack track;
  final BoxConstraints box;
  final OpenPage onOpen;
  final Widget menu, trailing;
  final double edge;

  @override
  Widget build(BuildContext context) {
    const side = 24.0;
    final queueWidth = (box.maxWidth * 0.34).clamp(320.0, 440.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: side),
          child: _Header(p: p, onOpen: onOpen, edge: edge, trailing: trailing),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(side, 0, side, side),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, area) {
                      final art = (area.maxHeight - 300).clamp(160.0, 420.0).clamp(0.0, area.maxWidth);
                      return Center(
                        child: SingleChildScrollView(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: (art + 140).clamp(380.0, 560.0)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _BigCover(p: p, track: track, size: art),
                                const SizedBox(height: 28),
                                _Info(p: p, track: track, onOpen: onOpen, menu: menu),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        crossAxisAlignment: WrapCrossAlignment.center,
                                        children: [QualityMenu(p: p), _AlbumChip(track: track, onOpen: onOpen)],
                                      ),
                                    ),
                                    VolumeControl(p: p),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                SeekBar(p: p),
                                const SizedBox(height: 4),
                                _Transport(p: p, play: 76),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 40),
                SizedBox(
                  width: queueWidth,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.26),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: FocusTraversalGroup(
                      child: _QueueScroll(p: p, side: 10, top: 16, onOpen: onOpen),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _WideLyrics extends StatelessWidget {
  const _WideLyrics({
    required this.p,
    required this.track,
    required this.box,
    required this.onOpen,
    required this.menu,
    required this.trailing,
    required this.edge,
  });

  final PlayerState p;
  final PlayTrack track;
  final BoxConstraints box;
  final OpenPage onOpen;
  final Widget menu, trailing;
  final double edge;

  @override
  Widget build(BuildContext context) {
    final col = (box.maxWidth * 0.3).clamp(260.0, 380.0);
    final gap = box.maxWidth >= 1200 ? 72.0 : 40.0;
    final next = p.next;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _Header(p: p, onOpen: onOpen, edge: edge, trailing: trailing),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: gap),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: col,
                  child: LayoutBuilder(
                    builder: (context, area) {
                      final art = (area.maxHeight - 140).clamp(96.0, col);
                      return Center(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _BigCover(p: p, track: track, size: art),
                              const SizedBox(height: 24),
                              _Info(p: p, track: track, onOpen: onOpen, menu: menu),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SizedBox(width: gap),
                Expanded(child: LyricsView(p: p, track: track, fontSize: box.maxWidth >= 1200 ? 34 : 28)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            children: [
              SeekBar(p: p),
              Row(
                children: [
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: QualityMenu(p: p)),
                  ),
                  _Transport(p: p, play: 60, skip: 48, toggle: 44, maxWidth: 320),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (next != null)
                          Flexible(
                            child: Text(
                              'Далее: ${next.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: muted),
                            ),
                          ),
                        VolumeControl(p: p),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NarrowCover extends StatelessWidget {
  const _NarrowCover({
    required this.p,
    required this.track,
    required this.phone,
    required this.side,
    required this.onOpen,
    required this.menu,
    required this.onQueue,
    this.compact,
    this.minHeight = 0,
  });

  final PlayerState p;
  final PlayTrack track;
  final bool phone;
  final double side;
  final OpenPage onOpen;
  final Widget menu;
  final VoidCallback onQueue;
  final Widget? compact;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final pad = EdgeInsets.symmetric(horizontal: phone ? side : 0);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final height = MediaQuery.sizeOf(context).height;
        final top = phone
            ? Stack(
                children: [
                  ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (r) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      stops: [0, 0.62, 1],
                    ).createShader(r),
                    child: Center(
                      child: Cover(
                        url: p.art.isNotEmpty ? p.art : track.cover,
                        size: (height - 380).clamp(w < 200 ? w : 200.0, w),
                        radius: 0,
                        kind: ReleaseKind.track,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    top: 0,
                    child: _Header(p: p, onOpen: onOpen, onImage: true, trailing: _QueueButton(onPressed: onQueue, onImage: true)),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    p: p,
                    onOpen: onOpen,
                    edge: compact != null ? 96 : 48,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [?compact, _QueueButton(onPressed: onQueue)],
                    ),
                  ),
                  _BigCover(p: p, track: track, size: (w * 0.62).clamp(120.0, 360.0)),
                  const SizedBox(height: 24),
                ],
              );
        Widget column(List<Widget> children) => Padding(
          padding: pad,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        );
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  top,
                  column([
                    _Info(p: p, track: track, onOpen: onOpen, menu: menu),
                    const SizedBox(height: 8),
                    SeekBar(p: p),
                    const SizedBox(height: 4),
                    _Transport(p: p, skip: 52, play: w < 360 ? 64 : 72),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        QualityMenu(p: p),
                        const Spacer(),
                        if (!phone) VolumeControl(p: p),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (p.next != null) _NextCard(track: p.next!, onTap: onQueue),
                  ]),
                ],
              ),
              column([
                SizedBox(height: phone ? 16 : 8),
                _Actions(p: p, track: track),
                SizedBox(height: phone ? 12 : 24),
              ]),
            ],
          ),
        );
      },
    );
  }
}

class _QueueButton extends StatelessWidget {
  const _QueueButton({required this.onPressed, this.onImage = false});

  final VoidCallback onPressed;
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Очередь',
      style: onImage ? IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: 0.28)) : null,
      icon: const Icon(Icons.queue_music_rounded),
      onPressed: onPressed,
    );
  }
}

class _NextCard extends StatelessWidget {
  const _NextCard({required this.track, required this.onTap});

  final PlayTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: 'Далее: ${track.title}, ${track.artist}. Показать очередь',
      excludeSemantics: true,
      child: Material(
        color: Colors.black.withValues(alpha: 0.26),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            child: Row(
              children: [
                Cover(url: track.cover, size: 40, radius: 8, kind: ReleaseKind.track),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Далее', style: TextStyle(fontSize: 12, color: muted)),
                      Text(
                        '${track.title} · ${track.artist}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.queue_music_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.p, required this.track});

  final PlayerState p;
  final PlayTrack track;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: track.hasLyrics ? 'Текст песни' : 'У трека нет текста',
          onPressed: track.hasLyrics ? () => p.lyricsOpen.value = true : null,
          icon: const Icon(Icons.lyrics_outlined),
        ),
        IconButton(
          tooltip: 'Поделиться',
          onPressed: track.link.isEmpty ? null : () => p.share(track.link),
          icon: const Icon(Icons.share_outlined),
        ),
      ],
    );
  }
}

class _NarrowLyrics extends StatelessWidget {
  const _NarrowLyrics({required this.p, required this.track, required this.phone, required this.onOpen, this.compact});

  final PlayerState p;
  final PlayTrack track;
  final bool phone;
  final OpenPage onOpen;
  final Widget? compact;

  @override
  Widget build(BuildContext context) {
    final side = phone ? 16.0 : 24.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 8, side, 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Свернуть плеер',
                    icon: const Icon(Icons.expand_more_rounded),
                    onPressed: () => _close(p),
                  ),
                  const SizedBox(width: 4),
                  Cover(url: track.cover, size: 48, radius: 10, kind: ReleaseKind.track),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: TrackText(track: track, onOpen: onOpen),
                    ),
                  ),
                  if (p.wave) DislikeButton(p: p, track: track, size: 44),
                  LikeButton(p: p, track: track, size: 44),
                  ?compact,
                ],
              ),
              const SizedBox(height: 12),
              _ViewSwitch(p: p, track: track, labels: true),
              Expanded(child: LyricsView(p: p, track: track, fontSize: phone ? 24 : 28)),
              SeekBar(p: p),
              _Transport(p: p, skip: 52, play: 68),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueScroll extends StatefulWidget {
  const _QueueScroll({required this.p, required this.side, this.top = 0, this.onOpen});

  final PlayerState p;
  final double side, top;
  final OpenPage? onOpen;

  @override
  State<_QueueScroll> createState() => _QueueScrollState();
}

class _QueueScrollState extends State<_QueueScroll> {
  final _scroll = ScrollController();
  final _head = GlobalKey();
  late var _pos = widget.p.pos;

  PlayerState get p => widget.p;

  @override
  void initState() {
    super.initState();
    p.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    p.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  double get _headHeight => (_head.currentContext?.findRenderObject() as RenderBox?)?.size.height ?? 0;

  void _reveal() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final target = (_headHeight + p.pos * _rowExtent - pos.viewportDimension / 3).clamp(0.0, pos.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  void _changed() {
    final was = _pos;
    _pos = p.pos;
    if (was == _pos) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow(was, _pos));
  }

  void _follow(int was, int now) {
    if (!mounted || !_scroll.hasClients) return;
    final head = _headHeight;
    final pos = _scroll.position;
    bool visible(int i) {
      final top = head + i * _rowExtent;
      return top >= pos.pixels && top + _rowExtent <= pos.pixels + pos.viewportDimension;
    }

    if (!visible(was) || visible(now)) return;
    final target = (head + now * _rowExtent - pos.viewportDimension / 3).clamp(0.0, pos.maxScrollExtent);
    final d = motion(context, const Duration(milliseconds: 350));
    if (d == Duration.zero) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target, duration: d, curve: const Cubic(0.2, 0, 0, 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final side = widget.side;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final queue = p.queue;
        return CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, widget.top, side, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  key: _head,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        children: [
                          Semantics(
                            header: true,
                            child: const Text('Очередь', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: 8),
                          if (queue.isNotEmpty)
                            Text(
                              '${p.pos + 1} из ${queue.length}',
                              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, fontFeatures: tabular),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 0, side, 16),
              sliver: SliverFixedExtentList(
                itemExtent: _rowExtent,
                delegate: SliverChildBuilderDelegate(
                  (context, i) => QueueRow(
                    key: ValueKey('q$i-${queue[i].id}'),
                    track: queue[i],
                    current: i == p.pos,
                    playing: p.playing,
                    onOpen: widget.onOpen,
                    onTap: () => i == p.pos ? p.togglePlay() : p.jump(i),
                  ),
                  childCount: queue.length,
                ),
              ),
            ),
            if (p.wave)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(side + 6, 0, side, 24),
                  child: Text('Подбираю следующие треки…', style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _QueueFlyout extends StatelessWidget {
  const _QueueFlyout({required this.p, this.onOpen});

  final PlayerState p;
  final OpenPage? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = (MediaQuery.sizeOf(context).width * 0.9).clamp(0.0, 420.0);
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: Material(
          color: scheme.surfaceContainerLow,
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            left: false,
            child: Stack(
              children: [
                FocusTraversalGroup(
                  child: _QueueScroll(p: p, side: 12, top: 22, onOpen: onOpen),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    tooltip: 'Закрыть очередь',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class QueueRow extends StatelessWidget {
  const QueueRow({
    super.key,
    required this.track,
    required this.onTap,
    this.current = false,
    this.playing = false,
    this.onOpen,
  });

  final PlayTrack track;
  final VoidCallback onTap;
  final bool current, playing;
  final OpenPage? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: current,
      child: Material(
        color: current ? scheme.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                if (current)
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
                    child: Icon(
                      playing ? Icons.equalizer_rounded : Icons.pause_rounded,
                      color: context.status.accent,
                      size: 20,
                      semanticLabel: playing ? 'Играет' : 'На паузе',
                    ),
                  )
                else
                  Cover(url: track.cover, size: 40, radius: 6, kind: ReleaseKind.track),
                const SizedBox(width: 12),
                Expanded(
                  child: TrackText(track: track, accent: current, artistsOnly: true, onOpen: onOpen),
                ),
                const SizedBox(width: 12),
                Text(
                  fmtTime(track.duration),
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, fontFeatures: tabular),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
