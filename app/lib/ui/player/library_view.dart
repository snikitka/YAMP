import 'package:flutter/material.dart';

import '../../state/controller.dart';
import '../../state/models.dart';
import '../../state/player.dart';
import '../../theme.dart';
import '../download_menu.dart';
import '../widgets.dart';
import 'artist_view.dart';
import 'controls.dart';
import 'history_view.dart';
import 'home_view.dart';

class LibraryView extends StatefulWidget {
  const LibraryView({super.key, required this.c, required this.phone, this.collection = false});

  final Controller c;
  final bool phone, collection;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  PlayerState get p => widget.c.player;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      p.loadLibrary();
      if (!widget.phone) {
        p.openList(p.browse.value);
      } else if (!widget.collection) {
        p.loadHome();
      }
    });
  }

  void _open(String source) => p.browseTo(source, fromLibrary: true);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([p.browse, p.browsing]),
      builder: (context, _) {
        final source = p.browse.value;
        if (widget.phone) {
          final detail = p.browsing.value;
          return PopScope(
            canPop: !detail,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && !p.panelOpen.value) p.back();
            },
            child: detail
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: p.canBack ? 'Назад' : (widget.collection ? 'К коллекции' : 'На главную'),
                              icon: const Icon(Icons.arrow_back_rounded),
                              onPressed: p.back,
                            ),
                            Text(
                              p.canBack ? 'Назад' : (widget.collection ? 'Коллекция' : 'Главная'),
                              style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TrackListView(c: widget.c, source: source, phone: true),
                      ),
                    ],
                  )
                : widget.collection
                ? LibraryList(p: p, selected: null, onOpen: _open)
                : HomeView(c: widget.c, phone: true),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: MediaQuery.sizeOf(context).width >= 1100 ? 340 : 280,
              child: FocusTraversalGroup(
                child: LibraryList(p: p, selected: source, onOpen: _open, onHome: widget.c.home),
              ),
            ),
            VerticalDivider(width: 1, color: scheme.outlineVariant),
            Expanded(
              child: FocusTraversalGroup(
                child: TrackListView(c: widget.c, source: source, phone: false),
              ),
            ),
          ],
        );
      },
    );
  }
}

class LibraryList extends StatelessWidget {
  const LibraryList({super.key, required this.p, required this.selected, required this.onOpen, this.onHome});

  final PlayerState p;
  final String? selected;
  final void Function(String source) onOpen;
  final VoidCallback? onHome;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final lib = p.library;
        Widget heading(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
          child: Semantics(
            header: true,
            child: Text(
              s,
              style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
        );
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          children: [
            WaveCard(p: p),
            const SizedBox(height: 8),
            if (onHome != null)
              _SourceTile(icon: Icons.home_rounded, title: 'Главная', selected: selected == sourceHome, onTap: onHome!),
            _SourceTile(
              icon: Icons.favorite_rounded,
              title: 'Мне нравится',
              subtitle: lib.status == LoadStatus.ok || p.likedCount > 0 ? tracksCount(p.likedCount) : null,
              selected: selected == sourceLiked,
              onTap: () => onOpen(sourceLiked),
            ),
            _SourceTile(
              icon: Icons.history_rounded,
              title: 'История',
              selected: selected == sourceHistory,
              onTap: () => onOpen(sourceHistory),
            ),
            if (lib.status == LoadStatus.loading || lib.status == LoadStatus.idle)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (lib.status == LoadStatus.error)
              Problem(
                message: 'Не удалось загрузить плейлисты. ${lib.error}',
                onRetry: () => p.loadLibrary(force: true),
              )
            else ...[
              heading('Мои плейлисты'),
              if (lib.playlists.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Плейлистов пока нет. Создайте плейлист в Яндекс Музыке, и он появится здесь.',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.45),
                  ),
                ),
              for (final pl in lib.playlists)
                _PlaylistTile(pl: pl, selected: selected == pl.source, onTap: () => onOpen(pl.source)),
              if (lib.likedPlaylists.isNotEmpty) ...[
                heading('Понравившиеся плейлисты'),
                for (final pl in lib.likedPlaylists)
                  _PlaylistTile(pl: pl, selected: selected == pl.source, onTap: () => onOpen(pl.source)),
              ],
            ],
          ],
        );
      },
    );
  }
}

class WaveCard extends StatelessWidget {
  const WaveCard({super.key, required this.p});

  final PlayerState p;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = p.wave && (p.hasTrack || p.loading);
    final playing = on && p.playing;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: on ? p.togglePlay : () => p.play(sourceWave),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
                child: Icon(Icons.waves_rounded, color: context.status.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Моя волна', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(
                      on ? (playing ? 'Играет' : 'На паузе') : 'Музыка под ваш вкус',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.35),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                  child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: scheme.onPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _TileShell(
      selected: selected,
      onTap: onTap,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: context.status.accent),
      ),
      title: title,
      subtitle: subtitle,
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.pl, required this.selected, required this.onTap});

  final LibraryPlaylist pl;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final meta = [tracksCount(pl.count), if (pl.owner.isNotEmpty) pl.owner].join(' · ');
    return _TileShell(
      selected: selected,
      onTap: onTap,
      leading: Cover(url: pl.cover, size: 44, radius: 8, kind: ReleaseKind.playlist),
      title: pl.title,
      subtitle: meta,
    );
  }
}

class _TileShell extends StatelessWidget {
  const _TileShell({
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.title,
    this.subtitle,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Tooltip(
                    message: subtitle == null ? title : '$title\n$subtitle',
                    excludeFromSemantics: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, fontFeatures: tabular),
                          ),
                      ],
                    ),
                  ),
                ),
                if (selected) Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Problem extends StatelessWidget {
  const Problem({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, color: scheme.onSurfaceVariant, size: 32),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}

class TrackListView extends StatelessWidget {
  const TrackListView({super.key, required this.c, required this.source, required this.phone});

  final Controller c;
  final String source;
  final bool phone;

  PlayerState get p => c.player;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        if (source == sourceHome) return HomeView(c: c, phone: phone);
        final list = p.lists[source] ?? const TrackList(status: LoadStatus.idle);
        if (list.status == LoadStatus.idle) {
          WidgetsBinding.instance.addPostFrameCallback((_) => p.openList(source));
        }
        if (list.status == LoadStatus.loading || list.status == LoadStatus.idle) {
          return const Center(child: CircularProgressIndicator());
        }
        if (list.status == LoadStatus.error) {
          return Center(
            child: Problem(
              message: 'Не удалось открыть список. ${list.error}',
              onRetry: () => p.openList(source, force: true),
            ),
          );
        }
        final liked = source == sourceLiked;
        final history = source == sourceHistory;
        final tracks = list.tracks;
        final albums = list.albums;
        if (tracks.isEmpty && albums.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    liked
                        ? Icons.favorite_border_rounded
                        : (history ? Icons.history_rounded : Icons.queue_music_rounded),
                    size: 40,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    liked
                        ? 'Здесь будут ваши любимые треки'
                        : history
                        ? 'История пока пуста'
                        : (list.info?.kind == 'playlist'
                              ? 'В этом плейлисте пока нет треков'
                              : 'Здесь пока нет треков'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    liked
                        ? 'Отмечайте треки сердцем, и они появятся здесь.'
                        : history
                        ? 'Слушайте музыку, и треки появятся здесь по дням.'
                        : 'Добавьте треки в Яндекс Музыке, и они появятся здесь.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => p.play(sourceWave),
                    icon: const Icon(Icons.waves_rounded),
                    label: const Text('Включить Мою волну'),
                  ),
                ],
              ),
            ),
          );
        }
        if (history) return HistoryView(c: c, list: list, phone: phone);
        if (list.info?.kind == 'artist' && !isTopTracks(source)) {
          return ArtistView(c: c, source: source, list: list, phone: phone);
        }
        final pad = phone ? 12.0 : 20.0;
        final here = artistOfTop(source);
        return ListView.builder(
          key: PageStorageKey<String>('list:$source'),
          padding: EdgeInsets.fromLTRB(pad, phone ? 4 : 16, pad, 16),
          itemCount: tracks.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) return ListHeader(c: c, list: list, source: source, phone: phone);
            final t = tracks[i - 1];
            return TrackRow(
              key: ValueKey(t.id),
              c: c,
              track: t,
              number: i,
              here: here,
              onPlay: () => p.play(source, track: t.id),
            );
          },
        );
      },
    );
  }
}

class ListHeader extends StatelessWidget {
  const ListHeader({super.key, required this.c, required this.list, required this.source, required this.phone});

  final Controller c;
  final TrackList list;
  final String source;
  final bool phone;

  PlayerState get p => c.player;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final liked = source == sourceLiked;
    final info = list.info;
    final kind = liked ? sourceLiked : (info?.kind ?? 'playlist');
    final title = info?.title ?? (liked ? 'Мне нравится' : '');
    final here = p.source?.id == source && p.hasTrack;
    final playingHere = here && p.playing;
    final playable = list.tracks.where((t) => !t.unavailable).length;
    final top = isTopTracks(source);
    final artist = kind == 'artist' && !top;
    final waveable = const {'album', 'artist', 'playlist', 'track'}.contains(kind) && !liked && playable > 0;
    final over = switch (kind) {
      sourceLiked => 'Коллекция',
      sourceChart => 'Чарт',
      sourceHistory => 'Прослушивания',
      'album' => 'Альбом',
      'artist' when top => 'Популярные треки',
      'artist' => 'Исполнитель',
      'track' => 'Трек',
      _ => 'Плейлист',
    };
    final byArtist = kind == 'album' || kind == 'track';
    final first = list.tracks.firstOrNull;
    final rest = [
      if (kind == 'album' && (info?.year ?? 0) > 0) '${info!.year}',
      if (artist) releasesLabel(list.albums) else if (kind != 'track') tracksCount(list.tracks.length),
      if (kind != 'artist' && kind != sourceHistory && list.total > Duration.zero) fmtTotal(list.total),
    ].where((s) => s.isNotEmpty).join(' · ');
    final lead = [
      if (byArtist && (info?.artist ?? '').isNotEmpty) ...artistParts(info!.artists, info.artist),
      if (kind == 'track' && first != null && first.albumSource.isNotEmpty && first.album.isNotEmpty) ...[
        const LinkPart(' · '),
        LinkPart(first.album, first.albumSource),
      ],
    ];
    final meta = [
      ...lead,
      if (lead.isNotEmpty && rest.isNotEmpty) const LinkPart(' · '),
      if (rest.isNotEmpty) LinkPart(rest),
    ];
    final size = kind == 'artist' ? (phone ? 96.0 : 168.0) : (phone ? 72.0 : 120.0);
    final badge = switch (kind) {
      sourceLiked => Icons.favorite_rounded,
      sourceChart => Icons.leaderboard_rounded,
      sourceHistory => Icons.history_rounded,
      _ => null,
    };
    final art = badge != null
        ? Container(
            width: phone ? 72 : 120,
            height: phone ? 72 : 120,
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(16)),
            child: Icon(badge, size: phone ? 32 : 52, color: context.status.accent),
          )
        : Cover(
            url: info?.cover ?? '',
            size: size,
            radius: 16,
            kind: switch (kind) {
              'artist' => ReleaseKind.artist,
              'album' => ReleaseKind.album,
              'track' => ReleaseKind.track,
              _ => ReleaseKind.playlist,
            },
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!phone && p.canBack)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextButton.icon(
                onPressed: p.back,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Назад'),
              ),
            ),
          Row(
            children: [
              art,
              SizedBox(width: phone ? 14 : 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      over.toUpperCase(),
                      style: TextStyle(
                        color: context.status.accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            (artist
                                    ? (phone ? text.headlineSmall : text.displaySmall)
                                    : (phone ? text.titleLarge : text.headlineSmall))
                                ?.copyWith(height: 1.2, fontWeight: artist ? FontWeight.w800 : null),
                      ),
                    ),
                    const SizedBox(height: 4),
                    LinkText(
                      parts: meta,
                      onOpen: c.openPage,
                      maxLines: 2,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontFeatures: tabular),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: playable == 0 ? null : (here ? p.togglePlay : () => p.play(source)),
                icon: Icon(playingHere ? Icons.pause_rounded : Icons.play_arrow_rounded),
                label: Text(playingHere ? 'Пауза' : 'Слушать'),
              ),
              OutlinedButton.icon(
                onPressed: playable < 2 ? null : () => p.playShuffled(source),
                icon: const Icon(Icons.shuffle_rounded, size: 18),
                label: const Text('Вперемешку'),
              ),
              if (waveable)
                OutlinedButton.icon(
                  onPressed: () => p.playWave(
                    source: artistOfTop(source),
                    track: list.tracks.where((t) => !t.unavailable).firstOrNull,
                    title: title,
                  ),
                  icon: const Icon(Icons.waves_rounded, size: 18),
                  label: Text(switch (kind) {
                    'album' => 'Волна по альбому',
                    'artist' => 'Волна по исполнителю',
                    'track' => 'Волна по треку',
                    _ => 'Волна по плейлисту',
                  }),
                ),
              if (artistOfTop(source).startsWith('http'))
                OutlinedButton.icon(
                  onPressed: () => c.share(artistOfTop(source)),
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Поделиться'),
                ),
              if (!top && kind != sourceHistory)
                DownloadButton(
                  download: (link, q, name) => c.download(link, q, title: name),
                  link: liked ? sourceLiked : source,
                  title: title,
                  label: artist ? 'Скачать дискографию' : 'Скачать',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.c,
    required this.track,
    required this.number,
    required this.onPlay,
    this.here = '',
    this.dense = false,
  });

  final Controller c;
  final PlayTrack track;
  final int number;
  final VoidCallback onPlay;
  final String here;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = c.player;
    final current = p.isCurrent(track);
    final off = track.unavailable;
    final accent = context.status.accent;
    final compact = dense || MediaQuery.sizeOf(context).width < 420;
    final indicator = Icon(
      p.playing ? Icons.equalizer_rounded : Icons.pause_rounded,
      color: accent,
      size: 20,
      semanticLabel: p.playing ? 'Играет' : 'На паузе',
    );
    final row = Material(
      color: current ? scheme.surfaceContainerHigh : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: off ? null : (current ? p.togglePlay : onPlay),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              if (!compact) ...[
                SizedBox(
                  width: 32,
                  child: current
                      ? indicator
                      : Text(
                          '$number',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, fontFeatures: tabular),
                        ),
                ),
                const SizedBox(width: 8),
              ],
              if (compact && current)
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
                  child: indicator,
                )
              else
                Opacity(
                  opacity: off ? 0.45 : 1,
                  child: Cover(url: track.cover, size: 40, radius: 6, kind: ReleaseKind.track),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TitleWithBadge(
                      track.title,
                      explicit: track.explicit,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: off ? scheme.onSurfaceVariant : (current ? accent : null),
                      ),
                    ),
                    LinkText(
                      parts: off
                          ? const [LinkPart('Недоступен в каталоге')]
                          : artistParts(track.artists, track.artist, here: here),
                      onOpen: c.openPage,
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (!off && !dense) LikeButton(p: p, track: track, size: 36),
              const SizedBox(width: 4),
              SizedBox(
                width: 44,
                child: Text(
                  fmtTime(track.duration),
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, fontFeatures: tabular),
                ),
              ),
              _More(c: c, track: track, here: here, like: dense),
            ],
          ),
        ),
      ),
    );
    return Padding(padding: const EdgeInsets.only(bottom: 2), child: row);
  }
}

class _More extends StatelessWidget {
  const _More({required this.c, required this.track, required this.here, this.like = false});

  final Controller c;
  final PlayTrack track;
  final String here;
  final bool like;

  @override
  Widget build(BuildContext context) {
    final p = c.player;
    final disliked = p.disliked(track);
    final pages = track.unavailable ? const <Widget>[] : pageItems(track, c.openPage, here: here);
    return MenuAnchor(
      menuChildren: [
        ...pages,
        if (pages.isNotEmpty) const Divider(height: 8),
        if (like && !track.unavailable)
          MenuItemButton(
            leadingIcon: Icon(p.liked(track) ? Icons.favorite_rounded : Icons.favorite_border_rounded),
            onPressed: () => p.like(track, !p.liked(track)),
            child: Text(p.liked(track) ? 'Убрать из «Мне нравится»' : 'Мне нравится'),
          ),
        if (!track.unavailable)
          MenuItemButton(
            leadingIcon: const Icon(Icons.waves_rounded),
            onPressed: () => p.playWave(track: track),
            child: const Text(waveByTrack),
          ),
        if (track.link.isNotEmpty)
          MenuItemButton(
            leadingIcon: const Icon(Icons.share_outlined),
            onPressed: () => c.share(track.link),
            child: const Text('Поделиться'),
          ),
        if (!track.unavailable) ...[
          ...downloadItems((link, q, name) => c.download(link, q, title: name), track.link, track.title),
          const Divider(height: 8),
        ],
        MenuItemButton(
          leadingIcon: Icon(disliked ? Icons.thumb_down_alt_rounded : Icons.thumb_down_off_alt_rounded),
          onPressed: () => p.dislike(track, !disliked),
          child: Text(disliked ? 'Снова рекомендовать' : 'Не рекомендовать'),
        ),
      ],
      builder: (context, menu, _) => IconButton(
        tooltip: 'Ещё',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.more_vert_rounded),
      ),
    );
  }
}
