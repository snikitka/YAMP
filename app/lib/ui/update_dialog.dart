import 'dart:io';

import 'package:flutter/material.dart';

import '../state/controller.dart';
import '../state/models.dart';
import '../theme.dart';

Future<void> showUpdateDialog(BuildContext context, Controller c) {
  return showDialog(context: context, builder: (_) => _UpdateDialog(c: c));
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListenableBuilder(
          listenable: Listenable.merge([c, c.stats, c.updateProgress]),
          builder: (context, _) {
            final u = c.update;
            if (u == null || !u.available) return const SizedBox.shrink();
            final busy = c.downloading;
            var about = 'У вас версия ${u.current}.';
            if (u.published.isNotEmpty) about += ' Версия ${u.latest} вышла ${u.published}.';
            about += u.canApply
                ? Platform.isAndroid
                    ? ' YAMP скачает её и откроет установщик Android.'
                    : ' YAMP скачает её и перезапустится.'
                : ' Скачайте её со страницы релиза.';
            final notes = u.notes.length > 3000 ? '${u.notes.substring(0, 3000)}…' : u.notes;
            return Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.system_update_alt_rounded, color: context.status.accent),
                      const SizedBox(width: 12),
                      Expanded(child: Text('Доступна версия ${u.latest}', style: text.titleLarge)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(about, style: text.bodyMedium),
                  if (notes.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 240),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(14),
                        child: SelectableText(notes, style: text.bodySmall?.copyWith(height: 1.45)),
                      ),
                    ),
                  ],
                  if (c.updating) ...[
                    const SizedBox(height: 18),
                    LinearProgressIndicator(value: c.updateProgress.value),
                    const SizedBox(height: 8),
                    Text(
                      Platform.isAndroid
                          ? 'Скачиваю обновление, потом откроется установщик…'
                          : 'Скачиваю обновление, YAMP перезапустится сам…',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ] else if (u.canApply && busy) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Обновиться можно, когда закончатся загрузки.',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 20),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 8,
                    overflowSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => c.openLink(u.page),
                        child: const Text('Страница релиза'),
                      ),
                      TextButton(
                        onPressed: c.updating ? null : () => Navigator.pop(context),
                        child: const Text('Позже'),
                      ),
                      u.canApply
                          ? FilledButton(
                              autofocus: true,
                              onPressed: c.updating || busy ? null : c.applyUpdate,
                              child: const Text('Обновить'),
                            )
                          : FilledButton(
                              autofocus: true,
                              onPressed: () {
                                c.openLink(u.page);
                                Navigator.pop(context);
                              },
                              child: const Text('Скачать'),
                            ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class UpdateRow extends StatelessWidget {
  const UpdateRow({super.key, required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final u = c.update;
    final available = u != null && u.available;
    final status = switch (u) {
      _ when c.checkingUpdate => 'Проверяю обновления…',
      _ when c.updating => 'Скачиваю обновление…',
      UpdateInfo(:final error) when error.isNotEmpty => 'Не удалось проверить: $error',
      UpdateInfo(available: true, :final latest) => 'Доступна версия $latest',
      UpdateInfo() => 'Это последняя версия',
      null => 'Обновления приходят из релизов на GitHub',
    };
    final busy = c.checkingUpdate || c.updating;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.version.isEmpty ? 'YAMP' : 'Версия ${c.version}',
                style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(status, style: TextStyle(fontSize: 12.5, height: 1.4, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        available
            ? FilledButton(
                onPressed: busy ? null : () => showUpdateDialog(context, c),
                child: const Text('Обновить'),
              )
            : FilledButton.tonal(
                onPressed: busy ? null : c.checkUpdate,
                child: const Text('Проверить'),
              ),
      ],
    );
  }
}

class UpdateButton extends StatelessWidget {
  const UpdateButton({super.key, required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final u = c.update;
        if (u == null || !u.available) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: IconButton(
            tooltip: 'Доступна версия ${u.latest}',
            icon: Icon(Icons.system_update_alt_rounded, color: context.status.accent),
            onPressed: () => showUpdateDialog(context, c),
          ),
        );
      },
    );
  }
}
