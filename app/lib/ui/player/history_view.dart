import 'package:flutter/material.dart';

import '../../state/controller.dart';
import '../../state/player.dart';
import 'controls.dart';
import 'library_view.dart';

const _months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

String dayLabel(String date, DateTime now) {
  final d = DateTime.tryParse(date);
  if (d == null) return date;
  final day = DateTime.utc(d.year, d.month, d.day);
  final ago = DateTime.utc(now.year, now.month, now.day).difference(day).inDays;
  if (ago == 0) return 'Сегодня';
  if (ago == 1) return 'Вчера';
  final label = '${day.day} ${_months[day.month - 1]}';
  return day.year == now.year ? label : '$label ${day.year}';
}

class HistoryView extends StatelessWidget {
  const HistoryView({super.key, required this.c, required this.list, required this.phone});

  final Controller c;
  final TrackList list;
  final bool phone;

  PlayerState get p => c.player;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final rows = <(String, int, int)>[];
    var at = 0;
    for (final d in list.days) {
      final end = (at + d.count).clamp(0, list.tracks.length);
      if (end > at) rows.add((d.date, -1, end - at));
      for (var i = at; i < end; i++) {
        rows.add((d.date, i, i - at + 1));
      }
      at = end;
    }
    final pad = phone ? 12.0 : 20.0;
    return ListView.builder(
      key: const PageStorageKey<String>('list:$sourceHistory'),
      padding: EdgeInsets.fromLTRB(pad, phone ? 4 : 16, pad, 16),
      itemCount: rows.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return ListHeader(c: c, list: list, source: sourceHistory, phone: phone);
        final (date, index, n) = rows[i - 1];
        if (index < 0) return _DayTitle(label: dayLabel(date, now), count: n);
        final t = list.tracks[index];
        return TrackRow(
          key: ValueKey('$date:${t.id}'),
          c: c,
          track: t,
          number: n,
          onPlay: () => p.play(sourceHistory, track: t.id, index: index),
        );
      },
    );
  }
}

class _DayTitle extends StatelessWidget {
  const _DayTitle({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            tracksCount(count),
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, fontFeatures: tabular),
          ),
        ],
      ),
    );
  }
}
