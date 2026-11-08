import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../state/controller.dart';
import '../../state/player.dart';
import '../../state/search.dart';
import '../widgets.dart';
import '../search_view.dart';
import 'artist_view.dart';
import 'library_view.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key, required this.c, required this.phone});

  final Controller c;
  final bool phone;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  PlayerState get p => widget.c.player;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) p.loadHome();
    });
  }

  @override
  Widget build(BuildContext context) {
    final phone = widget.phone;
    final pad = phone ? 12.0 : 20.0;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final home = p.home;
        final later = [('Новые релизы', home.releases), ('Новые плейлисты', home.playlists)];
        Widget row(String title, List<SearchHit> hits, {String? more, VoidCallback? onMore}) =>
            _Row(c: widget.c, title: title, hits: hits, phone: phone, more: more, onMore: onMore);
        return ListView(
          key: const PageStorageKey<String>('home'),
          padding: EdgeInsets.fromLTRB(pad, phone ? 8 : 16, pad, 24),
          children: [
            if (phone) ...[WaveCard(p: p), const SizedBox(height: 8)],
            if (home.status == LoadStatus.loading || home.status == LoadStatus.idle)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (home.status == LoadStatus.error)
              Problem(message: 'Не удалось загрузить главную. ${home.error}', onRetry: () => p.loadHome(force: true))
            else ...[
              if (home.personal.isNotEmpty) row('Для вас', home.personal),
              if (home.history.isNotEmpty)
                row(
                  'Вы недавно слушали',
                  home.history,
                  more: 'Вся история',
                  onMore: () => widget.c.openPage(sourceHistory),
                ),
              if (home.chart.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 8),
                  child: SectionTitle('Чарт', more: 'Весь чарт', onMore: () => widget.c.openPage(sourceChart)),
                ),
                for (final (i, t) in home.chart.indexed)
                  TrackRow(
                    key: ValueKey('chart:${t.id}'),
                    c: widget.c,
                    track: t,
                    number: i + 1,
                    onPlay: () => p.play(sourceChart, track: t.id),
                  ),
              ],
              for (final (title, hits) in later)
                if (hits.isNotEmpty) row(title, hits),
            ],
          ],
        );
      },
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({required this.c, required this.title, required this.hits, required this.phone, this.more, this.onMore});

  final Controller c;
  final String title;
  final List<SearchHit> hits;
  final bool phone;
  final String? more;
  final VoidCallback? onMore;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  final _scroll = ScrollController();
  var _start = true, _end = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_edges);
    WidgetsBinding.instance.addPostFrameCallback((_) => _edges());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _edges() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final start = pos.pixels <= pos.minScrollExtent + 1;
    final end = pos.pixels >= pos.maxScrollExtent - 1;
    if (start == _start && end == _end) return;
    setState(() {
      _start = start;
      _end = end;
    });
  }

  void _page(int dir) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final to = (pos.pixels + dir * pos.viewportDimension * 0.8).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    final d = motion(context, const Duration(milliseconds: 350));
    if (d == Duration.zero) {
      _scroll.jumpTo(to);
    } else {
      _scroll.animateTo(to, duration: d, curve: const Cubic(0.2, 0, 0, 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = widget.phone;
    final size = phone ? 136.0 : 168.0;
    final list = ListView.separated(
      key: PageStorageKey<String>('home:${widget.title}'),
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      itemCount: widget.hits.length,
      separatorBuilder: (_, _) => const SizedBox(width: 4),
      itemBuilder: (context, i) => SizedBox(
        width: size,
        child: HitCard(c: widget.c, hit: widget.hits[i], size: size),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 4),
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                Expanded(
                  child: SectionTitle(widget.title, more: widget.more, onMore: widget.onMore),
                ),
                if (!phone && !(_start && _end) && (widget.onMore == null || box.maxWidth >= 480)) ...[
                  IconButton(
                    tooltip: 'Назад',
                    onPressed: _start ? null : () => _page(-1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  IconButton(
                    tooltip: 'Вперёд',
                    onPressed: _end ? null : () => _page(1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ],
            ),
          ),
        ),
        SizedBox(
          height: size + 64,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              _edges();
              return false;
            },
            child: phone
                ? list
                : ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(dragDevices: {...PointerDeviceKind.values}),
                    child: list,
                  ),
          ),
        ),
      ],
    );
  }
}
