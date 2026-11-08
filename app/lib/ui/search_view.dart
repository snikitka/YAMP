import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/controller.dart';
import '../state/models.dart';
import '../state/search.dart';
import '../theme.dart';
import 'download_menu.dart';
import 'widgets.dart';

String sectionTitle(ReleaseKind k) => switch (k) {
  ReleaseKind.track => 'Треки',
  ReleaseKind.album => 'Альбомы',
  ReleaseKind.artist => 'Исполнители',
  ReleaseKind.playlist => 'Плейлисты',
};

String duration(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

String hitOver(SearchHit h) => switch (h.kind) {
  ReleaseKind.album => switch (h.type) {
    'single' => 'Сингл',
    'compilation' => 'Сборник',
    _ => 'Альбом',
  },
  _ => h.kind.label,
};

String hitSubtitle(SearchHit h) => switch (h.kind) {
  ReleaseKind.track => [h.artist, h.album].where((s) => s.isNotEmpty).join(' · '),
  ReleaseKind.album => [h.artist, if (h.year > 0) '${h.year}'].where((s) => s.isNotEmpty).join(' · '),
  ReleaseKind.artist => h.count > 0 ? tracksLabel(h.count) : 'Исполнитель',
  ReleaseKind.playlist => [h.artist, if (h.count > 0) tracksLabel(h.count)].where((s) => s.isNotEmpty).join(' · '),
};

class SearchView extends StatelessWidget {
  const SearchView({super.key, required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final s = c.search;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final r = s.results;
        final status = switch (r?.status) {
          null || SearchStatus.loading => 'Ищу «${s.query}»',
          SearchStatus.error => 'Поиск не удался',
          SearchStatus.ok when r!.empty => 'Ничего не нашлось',
          SearchStatus.ok => 'Результаты по запросу «${s.query}»',
        };
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): s.close},
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Filters(c: c),
              Expanded(
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  label: status,
                  child: switch (r?.status) {
                    null || SearchStatus.loading => const Center(
                      child: SizedBox.square(
                        dimension: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.6, semanticsLabel: 'Ищу'),
                      ),
                    ),
                    SearchStatus.error => _Message(
                      icon: Icons.cloud_off_rounded,
                      title: 'Поиск не удался',
                      body: r!.message,
                      action: FilledButton.tonal(onPressed: s.retry, child: const Text('Повторить')),
                    ),
                    SearchStatus.ok when r!.empty => _Message(
                      icon: Icons.search_off_rounded,
                      title: 'Ничего не нашлось',
                      body: 'По запросу «${s.query}» ничего нет. Проверьте написание или поищите по имени исполнителя.',
                      action: r.corrected.isEmpty ? null : _Corrected(c: c, text: r.corrected),
                    ),
                    SearchStatus.ok when s.filter == null => _AllResults(c: c, r: r!),
                    SearchStatus.ok => _KindResults(c: c, r: r!, kind: s.filter!),
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = c.search;
    final all = s.all;
    Widget chip(String label, ReleaseKind? kind) {
      final on = s.filter == kind;
      return ChoiceChip(
        label: Text(label),
        selected: on,
        showCheckmark: false,
        onSelected: (_) => s.setFilter(kind),
        selectedColor: scheme.primary,
        labelStyle: TextStyle(fontWeight: FontWeight.w600, color: on ? scheme.onPrimary : scheme.onSurface),
        shape: StadiumBorder(side: BorderSide(color: on ? scheme.primary : scheme.outlineVariant)),
      );
    }

    final kinds = [
      for (final k in searchKinds)
        if (all == null || all.status != SearchStatus.ok || (all[k]?.hits.isNotEmpty ?? false)) k,
    ];
    final chips = [chip('Всё', null), for (final k in kinds) chip(sectionTitle(k), k)];
    final phone = isPhone(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(phone ? 16 : 28, phone ? 10 : 16, phone ? 4 : 16, 8),
      child: Row(
        children: [
          Expanded(
            child: phone
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (i, w) in chips.indexed) ...[if (i > 0) const SizedBox(width: 8), w],
                      ],
                    ),
                  )
                : Wrap(spacing: 8, runSpacing: 8, children: chips),
          ),
          const SizedBox(width: 8),
          IconButton(tooltip: 'Закрыть поиск', onPressed: s.close, icon: const Icon(Icons.close_rounded)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body, this.action});

  final IconData icon;
  final String title, body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class _Corrected extends StatelessWidget {
  const _Corrected({required this.c, required this.text});

  final Controller c;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Возможно, вы искали ', style: TextStyle(color: scheme.onSurfaceVariant)),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            c.search.input.text = text;
            c.search.input.selection = TextSelection.collapsed(offset: text.length);
            c.search.run(text);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Text(
              '«$text»',
              style: TextStyle(color: context.status.accent, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onAll});

  final String title;
  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      margin: const EdgeInsets.only(top: 16, bottom: 6),
      child: Row(
        children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          if (onAll != null) TextButton(onPressed: onAll, child: const Text('Показать все')),
        ],
      ),
    );
  }
}

class _AllResults extends StatelessWidget {
  const _AllResults({required this.c, required this.r});

  final Controller c;
  final SearchResults r;

  @override
  Widget build(BuildContext context) {
    final s = c.search;
    final best = r.best;
    final tracks = r[ReleaseKind.track]?.hits ?? const <SearchHit>[];
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 920;
        final top = tracks.take(wide && best != null ? 4 : 5).toList();
        Widget trackList(List<SearchHit> list) => Column(
          children: [for (final h in list) HitRow(c: c, hit: h)],
        );
        return ListView(
          padding: EdgeInsets.fromLTRB(sidePad(context), 0, sidePad(context), 28),
          children: [
            if (r.corrected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _Corrected(c: c, text: r.corrected),
              ),
            if (best != null && wide && top.isNotEmpty)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _SectionHeader(title: 'Лучший результат'),
                        BestCard(c: c, hit: best),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SectionHeader(
                          title: 'Треки',
                          onAll: tracks.length > top.length ? () => s.setFilter(ReleaseKind.track) : null,
                        ),
                        trackList(top),
                      ],
                    ),
                  ),
                ],
              )
            else ...[
              if (best != null) ...[const _SectionHeader(title: 'Лучший результат'), BestCard(c: c, hit: best)],
              if (top.isNotEmpty) ...[
                _SectionHeader(
                  title: 'Треки',
                  onAll: tracks.length > top.length ? () => s.setFilter(ReleaseKind.track) : null,
                ),
                trackList(top),
              ],
            ],
            for (final k in [ReleaseKind.album, ReleaseKind.artist, ReleaseKind.playlist])
              if (r[k]?.hits case final hits? when hits.isNotEmpty) ...[
                _SectionHeader(title: sectionTitle(k), onAll: () => s.setFilter(k)),
                HitGrid(c: c, hits: hits, rows: 1),
              ],
          ],
        );
      },
    );
  }
}

class _KindResults extends StatelessWidget {
  const _KindResults({required this.c, required this.r, required this.kind});

  final Controller c;
  final SearchResults r;
  final ReleaseKind kind;

  @override
  Widget build(BuildContext context) {
    final section = r[kind];
    final hits = section?.hits ?? const <SearchHit>[];
    if (hits.isEmpty) {
      return const _Message(icon: Icons.search_off_rounded, title: 'Ничего не нашлось', body: 'В этом разделе пусто.');
    }
    final footer = section!.more
        ? Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Center(
              child: r.loadingMore
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.4, semanticsLabel: 'Загружаю ещё'),
                    )
                  : OutlinedButton(onPressed: c.search.more, child: const Text('Показать ещё')),
            ),
          )
        : const SizedBox.shrink();
    if (kind == ReleaseKind.track) {
      return ListView.builder(
        padding: EdgeInsets.fromLTRB(sidePad(context), 4, sidePad(context), 28),
        itemCount: hits.length + 1,
        itemBuilder: (_, i) => i == hits.length ? footer : HitRow(c: c, hit: hits[i]),
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(sidePad(context), 12, sidePad(context), 28),
      children: [
        HitGrid(c: c, hits: hits),
        footer,
      ],
    );
  }
}

class HitRow extends StatelessWidget {
  const HitRow({super.key, required this.c, required this.hit});

  final Controller c;
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        canRequestFocus: false,
        onTap: () => c.openHit(hit),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Cover(url: hit.cover, size: 44, kind: hit.kind, radius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TitleWithBadge(
                      hit.title,
                      explicit: hit.explicit,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      hitSubtitle(hit),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (hit.duration > 0) ...[
                const SizedBox(width: 12),
                Text(
                  duration(hit.duration),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              const SizedBox(width: 12),
              if (hit.kind == ReleaseKind.track) ...[
                IconButton(
                  tooltip: 'Слушать',
                  onPressed: () => c.player.play(hit.link),
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(30),
                    minimumSize: const Size.square(30),
                    padding: EdgeInsets.zero,
                  ),
                  iconSize: 20,
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
                const SizedBox(width: 8),
              ],
              DownloadButton(download: _download(c), link: hit.link, title: hit.title, size: 34),
            ],
          ),
        ),
      ),
    );
  }
}

class HitGrid extends StatelessWidget {
  const HitGrid({super.key, required this.c, required this.hits, this.rows});

  final Controller c;
  final List<SearchHit> hits;
  final int? rows;

  @override
  Widget build(BuildContext context) {
    const gap = 16.0, minWidth = 150.0;
    return LayoutBuilder(
      builder: (context, box) {
        final perRow = ((box.maxWidth + gap) ~/ (minWidth + gap)).clamp(2, 8);
        final width = (box.maxWidth - gap * (perRow - 1)) / perRow;
        final shown = rows == null ? hits : hits.take(perRow * rows!).toList();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final h in shown)
              SizedBox(
                width: width,
                child: HitCard(c: c, hit: h, size: width),
              ),
          ],
        );
      },
    );
  }
}

class HitCard extends StatelessWidget {
  const HitCard({super.key, required this.c, required this.hit, required this.size});

  final Controller c;
  final SearchHit hit;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final artist = hit.kind == ReleaseKind.artist;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        canRequestFocus: false,
        onTap: () => c.openHit(hit),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: artist ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Cover(url: hit.cover, size: size - 16, kind: hit.kind, radius: 10),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: IconButton.filled(
                      tooltip: 'Слушать',
                      onPressed: () => c.player.play(hit.link),
                      style: IconButton.styleFrom(
                        fixedSize: const Size.square(36),
                        minimumSize: const Size.square(36),
                        padding: EdgeInsets.zero,
                      ),
                      iconSize: 22,
                      icon: const Icon(Icons.play_arrow_rounded),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (artist)
                Tooltip(
                  message: hit.title,
                  child: Text(
                    hit.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                )
              else
                TitleWithBadge(
                  hit.title,
                  explicit: hit.explicit,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              const SizedBox(height: 2),
              Text(
                artist ? hitSubtitle(hit) : [hitOver(hit), hitSubtitle(hit)].where((x) => x.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BestCard extends StatelessWidget {
  const BestCard({super.key, required this.c, required this.hit});

  final Controller c;
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sub = hitSubtitle(hit);
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        canRequestFocus: false,
        onTap: () => c.openHit(hit),
        child: Padding(
          padding: EdgeInsets.all(isPhone(context) ? 14 : 18),
          child: Row(
            children: [
              Cover(url: hit.cover, size: isPhone(context) ? 76 : 104, kind: hit.kind, radius: 12),
              SizedBox(width: isPhone(context) ? 14 : 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hitOver(hit).toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: context.status.accent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    TitleWithBadge(
                      hit.title,
                      explicit: hit.explicit,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4),
                    ),
                    if (sub.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () => c.player.play(hit.link),
                          icon: const Icon(Icons.play_arrow_rounded, size: 20),
                          label: const Text('Слушать'),
                        ),
                        DownloadButton(download: _download(c), link: hit.link, title: hit.title),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Download _download(Controller c) => (link, q, title) => c.download(link, q, title: title);
