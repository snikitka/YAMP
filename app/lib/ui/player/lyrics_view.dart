import 'package:flutter/material.dart';

import '../../state/player.dart';
import '../widgets.dart';
import 'controls.dart';

class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.p, required this.track, this.fontSize = 30});

  final PlayerState p;
  final PlayTrack track;
  final double fontSize;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final _scroll = ScrollController();
  var _keys = <GlobalKey>[];
  var _line = -1;
  DateTime? _manual;

  PlayerState get p => widget.p;

  Lyrics? get _lyrics => p.lyrics[widget.track.id];

  @override
  void initState() {
    super.initState();
    p.addListener(_changed);
    p.position.addListener(_tick);
    _load();
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (old.track.id == widget.track.id) return;
    _line = -1;
    _manual = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  @override
  void dispose() {
    p.removeListener(_changed);
    p.position.removeListener(_tick);
    _scroll.dispose();
    super.dispose();
  }

  void _load() {
    final t = widget.track;
    if (!t.hasLyrics) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) p.loadLyrics(t);
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _tick() {
    final l = _lyrics;
    if (l == null || !l.synced) return;
    final i = l.lineAt(p.position.value);
    if (i == _line) return;
    setState(() => _line = i);
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  void _follow() {
    final manual = _manual;
    if (manual != null && DateTime.now().difference(manual) < const Duration(seconds: 4)) return;
    final i = _line < 0 ? 0 : _line;
    if (i >= _keys.length) return;
    final ctx = _keys[i].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.35,
      duration: motion(context, const Duration(milliseconds: 450)),
      curve: const Cubic(0.2, 0, 0, 1),
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) _manual = DateTime.now();
    if (n is ScrollUpdateNotification && n.dragDetails != null) _manual = DateTime.now();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l = _lyrics;
    if (!widget.track.hasLyrics || (l != null && l.status == LoadStatus.ok && l.lines.isEmpty)) {
      return const _Note(icon: Icons.lyrics_outlined, text: 'Для этого трека нет текста');
    }
    if (l == null || l.status == LoadStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (l.status == LoadStatus.error) {
      return _Note(
        icon: Icons.cloud_off_rounded,
        text: 'Не удалось загрузить текст: ${l.error}',
        action: TextButton(onPressed: () => p.loadLyrics(widget.track, force: true), child: const Text('Повторить')),
      );
    }
    if (_keys.length != l.lines.length) _keys = [for (final _ in l.lines) GlobalKey()];
    if (l.synced && _line < 0) _line = l.lineAt(p.position.value);
    final white = Colors.white;
    final size = widget.fontSize;
    return LayoutBuilder(
      builder: (context, box) {
        final edge = l.synced ? box.maxHeight * 0.3 : 8.0;
        return NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.symmetric(vertical: edge),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < l.lines.length; i++)
                    _Line(
                      key: _keys[i],
                      line: l.lines[i],
                      size: size,
                      color: !l.synced
                          ? white.withValues(alpha: 0.86)
                          : i == _line
                          ? white
                          : (i < _line ? white.withValues(alpha: 0.38) : white.withValues(alpha: 0.6)),
                      onTap: l.synced ? () => p.seek(l.lines[i].at!) : null,
                    ),
                  if (l.writers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Text(
                        'Авторы: ${l.writers.join(', ')}',
                        style: TextStyle(fontSize: 13, color: white.withValues(alpha: 0.62)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({super.key, required this.line, required this.size, required this.color, this.onTap});

  final LyricLine line;
  final double size;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final empty = line.text.isEmpty;
    final text = AnimatedDefaultTextStyle(
      duration: motion(context, const Duration(milliseconds: 250)),
      style: TextStyle(
        fontSize: empty ? size * 0.7 : size,
        fontWeight: FontWeight.w800,
        height: 1.22,
        letterSpacing: -0.01 * size,
        color: color,
      ),
      child: Text(empty ? '· · ·' : line.text),
    );
    final pad = EdgeInsets.symmetric(vertical: size * 0.22, horizontal: 8);
    if (onTap == null) return Padding(padding: pad, child: text);
    return Semantics(
      button: true,
      hint: 'Перейти к ${fmtTime(line.at!)}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(padding: pad, child: text),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final muted = Colors.white.withValues(alpha: 0.72);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: muted),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: muted)),
            ?action,
          ],
        ),
      ),
    );
  }
}
