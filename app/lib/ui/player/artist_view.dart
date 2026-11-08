import 'dart:math';

import 'package:flutter/material.dart';

import '../../state/controller.dart';
import '../../state/models.dart';
import '../../state/player.dart';
import '../../theme.dart';
import '../widgets.dart';
import 'controls.dart';
import 'library_view.dart';

const _topRows = 3;

String _plural(int n, String one, String few, String many) {
  final mod10 = n % 10, mod100 = n % 100;
  final word = mod10 == 1 && mod100 != 11
      ? one
      : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14) ? few : many);
  return '$n $word';
}

String releasesLabel(List<SourceAlbum> albums) {
  final full = albums.where((a) => a.type == 'album').length;
  final singles = albums.where((a) => a.type == 'single').length;
  final other = albums.length - full - singles;
  return [
    if (full > 0) _plural(full, 'альбом', 'альбома', 'альбомов'),
    if (singles > 0) _plural(singles, 'сингл', 'сингла', 'синглов'),
    if (other > 0) _plural(other, 'сборник', 'сборника', 'сборников'),
  ].join(' · ');
}

String albumTypeLabel(String type) => switch (type) {
  'single' => 'Сингл',
  'compilation' => 'Сборник',
  _ => 'Альбом',
};

int topColumns(double width) => width >= 960 ? 3 : (width >= 620 ? 2 : 1);

class ArtistView extends StatelessWidget {
  const ArtistView({super.key, required this.c, required this.source, required this.list, required this.phone});

  final Controller c;
  final String source;
  final TrackList list;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final pad = phone ? 12.0 : 20.0;
    List<SourceAlbum> ofType(bool Function(String) test) {
      final out = list.albums.where((a) => test(a.type)).toList();
      out.sort((a, b) => b.year.compareTo(a.year));
      return out;
    }

    final groups = [
      ('Альбомы', ofType((t) => t == 'album')),
      ('Синглы и EP', ofType((t) => t == 'single')),
      ('Сборники', ofType((t) => t != 'album' && t != 'single')),
    ];
    return CustomScrollView(
      key: PageStorageKey<String>('artist:$source'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, phone ? 4 : 16, pad, 0),
          sliver: SliverToBoxAdapter(
            child: ListHeader(c: c, list: list, source: source, phone: phone),
          ),
        ),
        if (list.tracks.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            sliver: SliverToBoxAdapter(
              child: _TopTracks(c: c, source: source, tracks: list.tracks),
            ),
          ),
        for (final (title, albums) in groups)
          if (albums.isNotEmpty) ...[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, 28, pad, 12),
              sliver: SliverToBoxAdapter(child: SectionTitle(title)),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: pad + 6),
              sliver: _AlbumGrid(p: c.player, albums: albums, phone: phone),
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.more, this.onMore});

  final String title;
  final String? more;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Semantics(
              header: true,
              child: Text(title, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            ),
          ),
        ),
        if (onMore != null)
          TextButton(
            onPressed: onMore,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [Text(more ?? 'Все'), const Icon(Icons.chevron_right_rounded, size: 20)],
            ),
          ),
      ],
    );
  }
}

class _TopTracks extends StatelessWidget {
  const _TopTracks({required this.c, required this.source, required this.tracks});

  final Controller c;
  final String source;
  final List<PlayTrack> tracks;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final columns = min(topColumns(box.maxWidth), (tracks.length / _topRows).ceil());
        final shown = min(tracks.length, columns * _topRows);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 28),
            SectionTitle(
              'Популярные треки',
              more: 'Все треки',
              onMore: tracks.length > shown ? () => c.player.browseTo(topTracksOf(source)) : null,
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var col = 0; col < columns; col++) ...[
                  if (col > 0) const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      children: [
                        for (var i = col * _topRows; i < min(shown, (col + 1) * _topRows); i++)
                          TrackRow(
                            key: ValueKey(tracks[i].id),
                            c: c,
                            track: tracks[i],
                            number: i + 1,
                            here: source,
                            dense: true,
                            onPlay: () => c.player.play(source, track: tracks[i].id),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.p, required this.albums, required this.phone});

  final PlayerState p;
  final List<SourceAlbum> albums;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    return SliverLayoutBuilder(
      builder: (context, box) {
        final gap = phone ? 12.0 : 20.0;
        final widest = phone ? 180.0 : 210.0;
        final w = box.crossAxisExtent;
        final columns = max(2, ((w + gap) / (widest + gap)).ceil());
        final side = (w - gap * (columns - 1)) / columns;
        final textHeight = scale.scale(14) * 1.4 + scale.scale(12.5) * 1.4;
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: 16,
            mainAxisExtent: side + 10 + textHeight + 4,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => AlbumCard(key: ValueKey(albums[i].source), p: p, album: albums[i], size: side),
            childCount: albums.length,
          ),
        );
      },
    );
  }
}

class AlbumCard extends StatefulWidget {
  const AlbumCard({super.key, required this.p, required this.album, required this.size});

  final PlayerState p;
  final SourceAlbum album;
  final double size;

  @override
  State<AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<AlbumCard> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = widget.p;
    final a = widget.album;
    final meta = [if (a.year > 0) '${a.year}', albumTypeLabel(a.type)].join(' · ');
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final here = p.source?.id == a.source && p.hasTrack;
        final playing = here && p.playing;
        return Semantics(
          button: true,
          label: '${albumTypeLabel(a.type)} ${a.title}${a.year > 0 ? ', ${a.year}' : ''}',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => p.browseTo(a.source),
            onHover: (v) => setState(() => _hover = v),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    Cover(url: a.cover, size: widget.size, radius: 12, kind: ReleaseKind.album),
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: ExcludeFocus(
                        child: AnimatedOpacity(
                          opacity: _hover || here ? 1 : 0,
                          duration: motion(context, const Duration(milliseconds: 150)),
                          child: IgnorePointer(
                            ignoring: !_hover && !here,
                            child: IconButton.filled(
                              tooltip: playing ? 'Пауза' : 'Слушать',
                              onPressed: here ? p.togglePlay : () => p.play(a.source),
                              style: IconButton.styleFrom(
                                fixedSize: const Size.square(44),
                                backgroundColor: scheme.primary,
                                foregroundColor: scheme.onPrimary,
                                elevation: 2,
                              ),
                              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TitleWithBadge(
                  a.title,
                  explicit: a.explicit,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: here ? context.status.accent : null,
                  ),
                ),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, fontFeatures: tabular),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
