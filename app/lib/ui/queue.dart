import 'package:flutter/material.dart';

import '../state/controller.dart';
import '../state/models.dart';
import '../theme.dart';
import 'widgets.dart';

class JobCard extends StatefulWidget {
  const JobCard({super.key, required this.job, required this.c});

  final Job job;
  final Controller c;

  @override
  State<JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<JobCard> {
  var _expanded = false;

  Job get job => widget.job;
  Controller get c => widget.c;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: job, builder: (context, _) => _card(context));
  }

  Color _accent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (job.status) {
      JobStatus.done => job.failed > 0 ? context.status.warning : context.status.success,
      JobStatus.error => scheme.error,
      JobStatus.cancelled => scheme.onSurfaceVariant,
      _ => scheme.primary,
    };
  }

  String _statusLine() {
    switch (job.status) {
      case JobStatus.resolving:
        return 'Получаю список треков…';
      case JobStatus.running:
        final parts = ['${job.completed} из ${job.total}'];
        final active = job.count(TrackStatus.active);
        if (active > 0) parts.add('качается $active');
        if (job.failed > 0) parts.add('ошибок ${job.failed}');
        return parts.join(' · ');
      default:
        return job.message;
    }
  }

  Widget _card(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final accent = _accent(context);
    final title = job.title.isNotEmpty ? job.title : job.link;
    final subtitle = [
      if (job.artist.isNotEmpty && job.kind != ReleaseKind.artist) job.artist,
      job.kind.label,
      if (job.year > 0) '${job.year}',
    ].join(' · ');
    final frac = job.fraction;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: job.tracks.length > 1 ? () => setState(() => _expanded = !_expanded) : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Cover(url: job.cover, size: 60, kind: job.kind),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TitleWithBadge(title, explicit: job.explicit, style: text.titleMedium),
                        if (job.title.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        const SizedBox(height: 10),
                        TweenAnimationBuilder<double>(
                          tween: Tween(end: frac ?? 0),
                          duration: motion(context, const Duration(milliseconds: 250)),
                          builder: (_, v, _) => LinearProgressIndicator(
                            value: frac == null ? null : v,
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _statusLine(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color:
                                      job.status == JobStatus.error ? scheme.error : scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            if (formatsLabel(job.formats) case final f when f.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Tag(f, color: f.startsWith('FLAC') ? context.status.accent : null),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ..._actions(),
                  if (job.tracks.length > 1)
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: motion(context, const Duration(milliseconds: 200)),
                      child: Icon(Icons.expand_more_rounded, color: scheme.onSurfaceVariant),
                    )
                  else
                    const SizedBox(width: 24),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: motion(context, const Duration(milliseconds: 240)),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded && job.tracks.length > 1 ? _trackList() : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  List<Widget> _actions() {
    if (!job.finished) {
      return [
        IconButton(
          tooltip: 'Остановить',
          icon: const Icon(Icons.stop_circle_outlined),
          onPressed: () => c.cancel(job.id),
        ),
      ];
    }
    return [
      if (job.dir.isNotEmpty || job.tracks.any((t) => t.path.isNotEmpty))
        IconButton(
          tooltip: 'Открыть папку',
          icon: const Icon(Icons.folder_open_rounded),
          onPressed: _open,
        ),
      if (job.status != JobStatus.done || job.failed > 0)
        IconButton(
          tooltip: 'Повторить (готовые треки пропустятся)',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () => c.retry(job.id),
        ),
      IconButton(
        tooltip: 'Убрать из списка',
        icon: const Icon(Icons.close_rounded),
        onPressed: () => c.remove(job.id),
      ),
    ];
  }

  void _open() {
    if (job.kind == ReleaseKind.track) {
      final path = job.tracks.isEmpty ? '' : job.tracks.first.path;
      if (path.isNotEmpty) {
        c.reveal(path);
        return;
      }
    }
    if (job.dir.isNotEmpty) c.openFolder(job.dir);
  }

  Widget _trackList() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Divider(height: 1, indent: 12, endIndent: 12, color: scheme.outlineVariant),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: job.tracks.length,
            itemExtent: 44,
            itemBuilder: (_, i) => _TrackRow(t: job.tracks[i], onReveal: c.reveal),
          ),
        ),
      ],
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.t, required this.onReveal});

  final TrackItem t;
  final void Function(String) onReveal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;

    final Widget lead = switch (t.status) {
      TrackStatus.active => SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(
            value: t.fraction,
            strokeWidth: 2.4,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
      TrackStatus.done => Icon(Icons.check_circle_rounded, size: 18, color: context.status.success),
      TrackStatus.skipped => Icon(Icons.check_circle_outline_rounded, size: 18, color: muted),
      TrackStatus.error => Icon(Icons.error_rounded, size: 18, color: scheme.error),
      TrackStatus.cancelled => Icon(Icons.remove_circle_outline_rounded, size: 18, color: muted),
      TrackStatus.queued => Text(
          '${t.index + 1}',
          style: TextStyle(color: muted, fontSize: 12.5, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
    };

    final Widget trail = switch (t.status) {
      TrackStatus.active => Text(
          t.size > 0 ? '${formatBytes(t.done)} / ${formatBytes(t.size)}' : formatBytes(t.done),
          style: TextStyle(color: muted, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      TrackStatus.done || TrackStatus.skipped => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (t.status == TrackStatus.skipped)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text('уже было', style: TextStyle(color: muted, fontSize: 12)),
              ),
            if (t.format.isNotEmpty)
              Tag(t.format, color: t.format.startsWith('FLAC') ? context.status.accent : null),
          ],
        ),
      TrackStatus.error => Flexible(
          child: Text(
            t.message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.error, fontSize: 12),
          ),
        ),
      _ => const SizedBox.shrink(),
    };

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          SizedBox(width: 28, child: Center(child: lead)),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: t.title),
                  if (t.explicit)
                    const WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(padding: EdgeInsets.only(left: 6), child: ExplicitBadge(size: 13)),
                    ),
                  if (t.artist.isNotEmpty)
                    TextSpan(text: '  ${t.artist}', style: TextStyle(color: muted, fontSize: 12.5)),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                color: t.status == TrackStatus.cancelled ? muted : scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 12),
          trail,
        ],
      ),
    );

    final tip = t.status == TrackStatus.error
        ? t.message
        : t.path.isNotEmpty
            ? 'Показать файл в папке'
            : t.title;
    final tappable = t.path.isNotEmpty ? InkWell(onTap: () => onReveal(t.path), child: row) : row;
    return tip.isEmpty ? tappable : Tooltip(message: tip, child: tappable);
  }
}
