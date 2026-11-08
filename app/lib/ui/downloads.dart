import 'package:flutter/material.dart';

import '../state/controller.dart';
import '../state/models.dart';
import 'queue.dart';
import 'widgets.dart';

class DownloadsButton extends StatelessWidget {
  const DownloadsButton({super.key, required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.stats, c.downloadsOpen, ...c.jobs]),
      builder: (context, _) {
        final running = c.jobs.where((j) => !j.finished).toList();
        final open = c.downloadsOpen.value;
        void toggle() => c.downloadsOpen.value = !open;
        if (running.isEmpty) {
          return IconButton(
            tooltip: 'Загрузки',
            isSelected: open,
            style: IconButton.styleFrom(
              shape: const CircleBorder(),
              side: BorderSide(color: open ? scheme.primary : scheme.outlineVariant),
            ),
            icon: const Icon(Icons.download_rounded),
            onPressed: toggle,
          );
        }
        final fractions = running.map((j) => j.fraction ?? 0);
        final progress = fractions.fold(0.0, (a, b) => a + b) / running.length;
        final speed = c.stats.value.speed;
        return Tooltip(
          message: 'Загрузки',
          child: Material(
            color: scheme.primary.withValues(alpha: open ? 0.22 : 0.12),
            shape: StadiumBorder(side: BorderSide(color: scheme.primary.withValues(alpha: 0.35))),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: toggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(5, 5, 10, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 30,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox.square(
                            dimension: 28,
                            child: CircularProgressIndicator(
                              value: progress.clamp(0.02, 1.0),
                              strokeWidth: 3,
                              color: scheme.primary,
                              backgroundColor: scheme.primary.withValues(alpha: 0.2),
                            ),
                          ),
                          Icon(Icons.arrow_downward_rounded, size: 15, color: scheme.primary),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (speed > 0)
                      Text(
                        '${formatBytes(speed)}/с',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    const SizedBox(width: 8),
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration:
                          BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(10)),
                      child: Text(
                        '${running.length}',
                        style: TextStyle(color: scheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class DownloadsPanel extends StatelessWidget {
  const DownloadsPanel({super.key, required this.c});

  final Controller c;

  Future<void> _stopAll(BuildContext context) async {
    final ok = await confirm(
      context,
      title: 'Остановить все загрузки?',
      body: 'Незавершённые задания: ${c.running}. Готовые треки останутся, '
          'а кнопка «Повторить» докачает остальное.',
      action: 'Остановить',
    );
    if (ok) c.cancelAll();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 16,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: Listenable.merge([c, c.stats]),
        builder: (context, _) {
          final jobs = c.jobs;
          final s = c.stats.value;
          final anyRunning = jobs.any((j) => !j.finished);
          final anyFinished = jobs.any((j) => j.finished);
          final line = s.busy
              ? '${formatBytes(s.speed)}/с · ${s.active} в работе'
                  '${s.queued > 0 ? ' · ${s.queued} в очереди' : ''}'
              : (jobs.isEmpty ? 'Пока ничего не качается' : 'Всё скачано');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Загрузки', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 2),
                          Text(
                            line,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => c.downloadsOpen.value = false,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: jobs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.download_done_rounded, size: 40, color: scheme.onSurfaceVariant),
                            const SizedBox(height: 10),
                            Text('Здесь появятся загрузки', style: TextStyle(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: jobs.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => JobCard(key: ValueKey(jobs[i].id), job: jobs[i], c: c),
                      ),
              ),
              if (anyRunning || anyFinished)
                Container(
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant))),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    children: [
                      if (anyRunning)
                        TextButton.icon(
                          style: TextButton.styleFrom(foregroundColor: scheme.error),
                          onPressed: () => _stopAll(context),
                          icon: const Icon(Icons.stop_circle_outlined, size: 18),
                          label: const Text('Остановить всё'),
                        ),
                      const Spacer(),
                      if (anyFinished)
                        TextButton(onPressed: c.clearFinished, child: const Text('Убрать завершённые')),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
