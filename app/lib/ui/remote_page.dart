import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../state/controller.dart';
import '../state/models.dart';
import '../state/player.dart';
import '../state/remote.dart';
import '../theme.dart';
import 'player/controls.dart';
import 'widgets.dart';

const pairPrefix = 'yamp://pair';

Future<void> openRemote(BuildContext context, Controller c) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RemotePage(c: c)));

class RemotePage extends StatefulWidget {
  const RemotePage({super.key, required this.c, this.scanner});

  final Controller c;
  final Future<String?> Function(BuildContext context)? scanner;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  RemoteState get r => widget.c.remote;

  @override
  void initState() {
    super.initState();
    widget.c.desktop.listenLan(true);
    r.scan(true);
  }

  @override
  void dispose() {
    r.scan(false);
    if (r.linkId.isNotEmpty && !r.target) r.disconnect();
    widget.c.desktop.listenLan(false);
    super.dispose();
  }

  Future<void> _scan() async {
    final scan =
        widget.scanner ?? (ctx) => Navigator.of(ctx).push(MaterialPageRoute<String>(builder: (_) => const ScanPage()));
    final link = await scan(context);
    if (link == null || !mounted) return;
    r.pair(link, name: await widget.c.desktop.deviceName());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) {
        final linked = r.linkId.isNotEmpty && r.status != LinkStatus.failed;
        return PopScope(
          canPop: !linked || r.target,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) r.disconnect();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(linked ? r.linkName : 'Пульт для компьютера'),
              actions: [
                if (linked)
                  IconButton(tooltip: 'Отключиться', icon: const Icon(Icons.link_off_rounded), onPressed: r.disconnect),
              ],
            ),
            body: SafeArea(
              child: linked ? _Control(r: r) : _Devices(r: r, onScan: _scan),
            ),
          ),
        );
      },
    );
  }
}

class RemoteBar extends StatelessWidget {
  const RemoteBar({super.key, required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c.remote,
      builder: (context, _) {
        final r = c.remote;
        if (!r.targeting) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final note = switch (r.status) {
          LinkStatus.online => 'Выбранная музыка включится на компьютере',
          LinkStatus.offline => 'Нет связи, подключаюсь снова',
          _ => 'Подключаюсь…',
        };
        return Material(
          color: scheme.primaryContainer,
          child: InkWell(
            onTap: () => openRemote(context, c),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
              child: Row(
                children: [
                  Icon(Icons.computer_rounded, color: scheme.onPrimaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          r.linkName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          note,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Отключить пульт',
                    color: scheme.onPrimaryContainer,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: r.disconnect,
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

class _Devices extends StatelessWidget {
  const _Devices({required this.r, required this.onScan});

  final RemoteState r;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paired = [
      for (final d in r.devices)
        if (d.paired) d,
    ];
    final found = [
      for (final d in r.devices)
        if (!d.paired) d,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (r.status == LinkStatus.failed && r.linkMessage.isNotEmpty) _Banner(message: r.linkMessage, error: true),
        if (r.scanError.isNotEmpty) _Banner(message: r.scanError, error: true),
        if (paired.isNotEmpty) ...[
          const _Heading('Связанные компьютеры'),
          for (final d in paired) _DeviceTile(r: r, d: d),
          const SizedBox(height: 20),
        ],
        if (found.isNotEmpty) ...[
          const _Heading('Рядом в сети'),
          for (final d in found) _DeviceTile(r: r, d: d),
          const SizedBox(height: 20),
        ],
        if (paired.isEmpty && found.isEmpty) ...[
          const SizedBox(height: 32),
          Icon(Icons.computer_rounded, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('Компьютеров пока нет', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
        ],
        Text(
          'На компьютере откройте YAMP, затем «Настройки», «Пульт с телефона» и нажмите «Показать QR-код». '
          'Телефон и компьютер должны быть в одной сети Wi-Fi.',
          textAlign: paired.isEmpty && found.isEmpty ? TextAlign.center : TextAlign.start,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
        ),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.icon(
            onPressed: r.status == LinkStatus.pairing ? null : onScan,
            icon: r.status == LinkStatus.pairing
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.qr_code_scanner_rounded),
            label: Text(r.status == LinkStatus.pairing ? 'Связываю…' : 'Сканировать QR-код'),
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            color: error ? scheme.onErrorContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: error ? scheme.onErrorContainer : scheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.r, required this.d});

  final RemoteState r;
  final RemoteDevice d;

  Future<void> _forget(BuildContext context) async {
    final ok = await confirm(
      context,
      title: 'Отвязать «${d.title}»?',
      body: 'Чтобы снова управлять этим компьютером, понадобится отсканировать QR-код.',
      action: 'Отвязать',
    );
    if (ok) r.forget(d);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = [
      if (d.login.isNotEmpty) d.login,
      if (!d.paired) 'отсканируйте QR-код на компьютере' else if (d.online) 'в сети' else 'не видно в сети',
    ].join(' · ');
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 8),
      color: scheme.surfaceContainerHigh,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        leading: Badge(
          isLabelVisible: d.online,
          backgroundColor: context.status.success,
          smallSize: 10,
          child: const Icon(Icons.computer_rounded),
        ),
        title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: d.paired ? () => r.connect(d) : null,
        trailing: d.paired
            ? IconButton(
                tooltip: 'Отвязать',
                icon: const Icon(Icons.link_off_rounded),
                onPressed: () => _forget(context),
              )
            : null,
      ),
    );
  }
}

class _Control extends StatelessWidget {
  const _Control({required this.r});

  final RemoteState r;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = r.track;
    final waiting = r.status != LinkStatus.online;
    return LayoutBuilder(
      builder: (context, box) {
        final cover = (box.maxHeight - 400).clamp(140.0, (box.maxWidth - 48).clamp(140.0, 360.0));
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (waiting)
                _Banner(
                  message: r.linkMessage.isNotEmpty ? r.linkMessage : 'Подключаюсь к компьютеру…',
                  error: r.status == LinkStatus.offline,
                ),
              const SizedBox(height: 8),
              Center(
                child: Cover(
                  url: t == null ? '' : (r.art.isNotEmpty ? r.art : t.cover),
                  size: cover,
                  kind: ReleaseKind.track,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                t?.title ?? (waiting ? '' : 'На компьютере ничего не играет'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                t?.artist ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (r.format.isNotEmpty) ...[const SizedBox(height: 6), Center(child: Tag(r.format))],
              const SizedBox(height: 16),
              _RemoteSeek(r: r),
              const SizedBox(height: 8),
              _Transport(r: r),
              const SizedBox(height: 16),
              _Volume(r: r),
              const SizedBox(height: 12),
              if (t != null) _Marks(r: r, track: t),
              const SizedBox(height: 16),
              Center(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    r.browse();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.library_music_rounded),
                  label: const Text('Выбрать музыку'),
                ),
              ),
              if (r.queue.isNotEmpty) ...[const SizedBox(height: 20), const _Heading('Очередь'), _Queue(r: r)],
            ],
          ),
        );
      },
    );
  }
}

class _RemoteSeek extends StatefulWidget {
  const _RemoteSeek({required this.r});

  final RemoteState r;

  @override
  State<_RemoteSeek> createState() => _RemoteSeekState();
}

class _RemoteSeekState extends State<_RemoteSeek> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final scheme = Theme.of(context).colorScheme;
    final time = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontFeatures: tabular);
    return ValueListenableBuilder(
      valueListenable: r.position,
      builder: (context, at, _) {
        final total = r.duration;
        final max = total.inMilliseconds > 0 ? total.inMilliseconds / 1000 : 1.0;
        final now = (_drag ?? at.inMilliseconds / 1000).clamp(0.0, max);
        return Column(
          children: [
            Slider(
              value: now,
              max: max,
              semanticFormatterCallback: (v) => '${fmtTime(Duration(seconds: v.round()))} из ${fmtTime(total)}',
              onChanged: r.connected && total > Duration.zero ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: (v) {
                setState(() => _drag = null);
                r.seek(Duration(milliseconds: (v * 1000).round()));
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fmtTime(Duration(milliseconds: (now * 1000).round())), style: time),
                  Text(fmtTime(total), style: time),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.r});

  final RemoteState r;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = r.connected && r.hasTrack;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ToggleButton(
          selected: r.shuffle,
          size: 44,
          icon: Icons.shuffle_rounded,
          selectedIcon: Icons.shuffle_on_rounded,
          tooltip: r.shuffle ? 'Перемешивание включено' : 'Перемешать',
          onPressed: on && !r.wave ? r.toggleShuffle : null,
        ),
        IconButton(
          tooltip: 'Предыдущий трек',
          iconSize: 36,
          onPressed: on ? r.previousTrack : null,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        IconButton.filled(
          tooltip: r.playing ? 'Пауза' : 'Слушать',
          iconSize: 40,
          onPressed: on ? r.togglePlay : null,
          style: IconButton.styleFrom(
            fixedSize: const Size.square(72),
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
          ),
          icon: Icon(r.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        IconButton(
          tooltip: 'Следующий трек',
          iconSize: 36,
          onPressed: on ? r.nextTrack : null,
          icon: const Icon(Icons.skip_next_rounded),
        ),
        ToggleButton(
          selected: r.repeat != Repeat.off,
          size: 44,
          icon: Icons.repeat_rounded,
          selectedIcon: r.repeat == Repeat.one ? Icons.repeat_one_on_rounded : Icons.repeat_on_rounded,
          tooltip: switch (r.repeat) {
            Repeat.off => 'Повтор выключен',
            Repeat.all => 'Повтор всех треков',
            Repeat.one => 'Повтор одного трека',
          },
          onPressed: on ? r.cycleRepeat : null,
        ),
      ],
    );
  }
}

class _Volume extends StatelessWidget {
  const _Volume({required this.r});

  final RemoteState r;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(r.volume == 0 ? Icons.volume_off_rounded : Icons.volume_down_rounded, color: scheme.onSurfaceVariant),
        Expanded(
          child: Slider(
            value: r.volume.clamp(0.0, 1.0),
            semanticFormatterCallback: (v) => 'Громкость ${(v * 100).round()}%',
            onChanged: r.connected ? r.setVolume : null,
            onChangeEnd: r.connected ? (v) => r.setVolume(v, done: true) : null,
          ),
        ),
        Icon(Icons.volume_up_rounded, color: scheme.onSurfaceVariant),
      ],
    );
  }
}

class _Marks extends StatelessWidget {
  const _Marks({required this.r, required this.track});

  final RemoteState r;
  final PlayTrack track;

  @override
  Widget build(BuildContext context) {
    final liked = r.liked(track);
    final disliked = r.disliked(track);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ToggleButton(
          selected: disliked,
          size: 48,
          icon: Icons.thumb_down_off_alt_rounded,
          selectedIcon: Icons.thumb_down_alt_rounded,
          tooltip: disliked ? 'Снова рекомендовать' : 'Не рекомендовать',
          onPressed: r.connected ? () => r.dislike(track, !disliked) : null,
        ),
        const SizedBox(width: 24),
        ToggleButton(
          selected: liked,
          size: 48,
          icon: Icons.favorite_border_rounded,
          selectedIcon: Icons.favorite_rounded,
          tooltip: liked ? 'Убрать из «Мне нравится»' : 'Мне нравится',
          onPressed: r.connected ? () => r.like(track, !liked) : null,
        ),
      ],
    );
  }
}

class _Queue extends StatelessWidget {
  const _Queue({required this.r});

  final RemoteState r;

  static const _ahead = 30;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final from = r.pos.clamp(0, r.queue.length);
    final to = (from + _ahead).clamp(0, r.queue.length);
    return Column(
      children: [
        for (var i = from; i < to; i++)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Cover(url: r.queue[i].cover, size: 40, kind: ReleaseKind.track),
            title: Text(
              r.queue[i].title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: i == r.pos ? TextStyle(color: context.status.accent, fontWeight: FontWeight.w600) : null,
            ),
            subtitle: Text(
              r.queue[i].artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            onTap: r.connected && i != r.pos ? () => r.jump(i) : null,
          ),
      ],
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  var _done = false;
  var _wrong = false;

  void _detect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue ?? '';
      if (raw.startsWith(pairPrefix)) {
        _done = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
    if (!_wrong) setState(() => _wrong = true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('QR-код с компьютера')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _detect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Разрешите YAMP доступ к камере в настройках телефона, чтобы отсканировать код'
                      : 'Камера не запустилась: ${error.errorDetails?.message ?? error.errorCode.name}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                _wrong
                    ? 'Это не код YAMP. Наведите камеру на QR-код в настройках YAMP на компьютере'
                    : 'Наведите камеру на QR-код в настройках YAMP на компьютере',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
