import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/remote.dart';
import '../theme.dart';
import 'player/controls.dart';
import 'widgets.dart';

class RemoteHostSection extends StatefulWidget {
  const RemoteHostSection({super.key, required this.r});

  final RemoteState r;

  @override
  State<RemoteHostSection> createState() => _RemoteHostSectionState();
}

class _RemoteHostSectionState extends State<RemoteHostSection> {
  Timer? _clock;
  DateTime? _renewed;

  RemoteState get r => widget.r;

  @override
  void initState() {
    super.initState();
    r.openHost();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    final until = r.pairUntil;
    if (until != null && r.pairLink.isNotEmpty && !DateTime.now().isBefore(until) && _renewed != until) {
      _renewed = until;
      r.startPairing();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _clock?.cancel();
    if (r.pairLink.isNotEmpty) r.stopPairing();
    super.dispose();
  }

  Future<void> _unpair(PairedPhone p) async {
    final ok = await confirm(
      context,
      title: 'Отвязать «${p.name}»?',
      body: 'Телефон больше не сможет управлять YAMP на этом компьютере, пока вы не свяжете их заново.',
      action: 'Отвязать',
    );
    if (ok) r.unpair(p);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final until = r.pairUntil;
        final left = until == null ? Duration.zero : until.difference(DateTime.now());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _hint(
              context,
              'Управляйте музыкой на компьютере с телефона: пауза, перемотка, громкость, лайки и переключение треков. '
              'На телефоне откройте YAMP, меню, «Пульт для компьютера» и отсканируйте код. '
              'Оба устройства должны быть в одной сети Wi-Fi. Если система спросит, пускать ли YAMP в сеть, '
              'разрешите доступ для частных сетей.',
            ),
            const SizedBox(height: 20),
            if (r.hostError.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(14)),
                child: Text(r.hostError, style: TextStyle(color: scheme.onErrorContainer)),
              ),
              const SizedBox(height: 16),
            ],
            if (r.pairLink.isNotEmpty) ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                  child: QrImageView(
                    data: r.pairLink,
                    size: 220,
                    padding: EdgeInsets.zero,
                    semanticsLabel: 'QR-код для связывания телефона',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                left > Duration.zero ? 'Код одноразовый и действует ещё ${fmtTime(left)}' : 'Обновляю код…',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: tabular),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: r.stopPairing,
                  icon: const Icon(Icons.visibility_off_rounded, size: 18),
                  label: const Text('Скрыть код'),
                ),
              ),
            ] else
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: r.startPairing,
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: Text(r.phones.isEmpty ? 'Показать QR-код' : 'Связать ещё телефон'),
                ),
              ),
            const SizedBox(height: 26),
            Text('Связанные телефоны', style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            if (r.phones.isEmpty)
              _hint(context, 'Пока ни одного. Без связывания компьютер не принимает команды ни от кого.')
            else
              for (final p in r.phones)
                Card.filled(
                  margin: const EdgeInsets.only(bottom: 8),
                  color: scheme.surfaceContainerHigh,
                  child: ListTile(
                    leading: Badge(
                      isLabelVisible: p.online,
                      backgroundColor: context.status.success,
                      smallSize: 10,
                      child: const Icon(Icons.smartphone_rounded),
                    ),
                    title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(p.online ? 'Подключён сейчас' : 'Не подключён'),
                    trailing: TextButton(onPressed: () => _unpair(p), child: const Text('Отвязать')),
                  ),
                ),
          ],
        );
      },
    );
  }

  Widget _hint(BuildContext context, String s) =>
      Text(s, style: TextStyle(fontSize: 12.5, height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant));
}
