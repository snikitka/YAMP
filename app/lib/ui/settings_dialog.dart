import 'package:flutter/material.dart';

import '../state/controller.dart';
import '../state/models.dart';
import '../state/player.dart';
import '../theme.dart';
import 'remote_host.dart';
import 'widgets.dart';
import 'update_dialog.dart';

Future<void> showSettingsDialog(BuildContext context, Controller c) {
  return showDialog(
    context: context,
    builder: (_) => _SettingsDialog(c: c),
  );
}

enum _Section {
  listening('Прослушивание', Icons.headphones_rounded),
  downloads('Загрузки', Icons.download_rounded),
  look('Оформление', Icons.palette_outlined),
  remote('Пульт с телефона', Icons.phonelink_ring_rounded),
  about('О программе', Icons.info_outline_rounded);

  const _Section(this.title, this.icon);

  final String title;
  final IconData icon;
}

String _short(PlayQuality q) => switch (q) {
  PlayQuality.lossless => 'FLAC',
  PlayQuality.mp3 => 'MP3 320',
  PlayQuality.low => 'Эконом',
};

String _summary(Controller c, _Section s) => switch (s) {
  _Section.listening =>
    c.playAuto ? 'Авто: Wi-Fi ${_short(c.playWifi)}, мобильный ${_short(c.playMobile)}' : _short(c.playManual),
  _Section.downloads => '${c.quality == Quality.lossless ? 'FLAC' : 'MP3 320'}, одновременно ${c.concurrency}',
  _Section.look => switch (c.theme) {
    ThemeChoice.system => 'Системная тема',
    ThemeChoice.light => 'Светлая тема',
    ThemeChoice.dark => 'Тёмная тема',
  },
  _Section.remote => switch (c.remote.phones.length) {
    0 => 'Телефон не связан',
    1 => 'Связан телефон «${c.remote.phones.first.name}»',
    final n => 'Связано телефонов: $n',
  },
  _Section.about => c.version.isEmpty ? 'YAMP' : 'Версия ${c.version}',
};

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.c});

  final Controller c;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  var _selected = _Section.listening;
  _Section? _open;

  Controller get c => widget.c;

  List<_Section> get _sections => [
    for (final s in _Section.values)
      if (s != _Section.remote || c.desktop.hostsRemote) s,
  ];

  @override
  void initState() {
    super.initState();
    if (c.desktop.hostsRemote) c.remote.openHost();
  }

  Widget _content(_Section s) => switch (s) {
    _Section.listening => _Listening(c: c),
    _Section.downloads => _Downloads(c: c),
    _Section.look => _Look(c: c),
    _Section.remote => RemoteHostSection(r: c.remote),
    _Section.about => _About(c: c),
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.remote]),
      builder: (context, _) => isPhone(context) ? _phone(context) : _desktop(context),
    );
  }

  Widget _desktop(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 780,
        height: (screen.height - 64).clamp(360.0, 580.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 210,
              color: scheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                    child: Text('Настройки', style: text.titleLarge),
                  ),
                  for (final s in _sections)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: _NavItem(section: s, selected: s == _selected, onTap: () => setState(() => _selected = s)),
                    ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      c.version.isEmpty ? 'YAMP' : 'YAMP ${c.version}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            VerticalDivider(width: 1, color: scheme.outlineVariant),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 14, 12, 0),
                    child: Row(
                      children: [
                        Expanded(child: Text(_selected.title, style: text.titleMedium)),
                        IconButton(
                          tooltip: 'Закрыть',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: ValueKey(_selected),
                      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
                      child: _content(_selected),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _phone(BuildContext context) {
    final open = _open;
    return PopScope(
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _open = null);
      },
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(open?.title ?? 'Настройки'),
            leading: IconButton(
              tooltip: open == null ? 'Закрыть' : 'Назад',
              icon: Icon(open == null ? Icons.close_rounded : Icons.arrow_back_rounded),
              onPressed: () => open == null ? Navigator.pop(context) : setState(() => _open = null),
            ),
          ),
          body: open == null
              ? ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    for (final s in _sections)
                      ListTile(
                        leading: Icon(s.icon),
                        title: Text(s.title),
                        subtitle: Text(_summary(c, s), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => setState(() => _open = s),
                      ),
                  ],
                )
              : SingleChildScrollView(
                  key: ValueKey(open),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  child: _content(open),
                ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.section, required this.selected, required this.onTap});

  final _Section section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Semantics(
          selected: selected,
          button: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(section.icon, size: 20, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    section.title,
                    style: TextStyle(color: fg, fontWeight: selected ? FontWeight.w600 : null),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Listening extends StatelessWidget {
  const _Listening({required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final detects = c.desktop.detectsNetwork;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Label('Качество звука'),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: true, icon: Icon(Icons.auto_awesome_rounded), label: Text('Авто')),
            ButtonSegment(value: false, icon: Icon(Icons.tune_rounded), label: Text('Вручную')),
          ],
          selected: {c.playAuto},
          onSelectionChanged: (s) => c.setPlayAuto(s.first),
        ),
        const SizedBox(height: 18),
        if (c.playAuto) ...[
          _QualityPick(
            icon: Icons.wifi_rounded,
            title: 'Wi-Fi и кабель',
            value: c.playWifi,
            onChanged: c.setPlayWifi,
            active: !c.metered,
          ),
          const SizedBox(height: 16),
          _QualityPick(
            icon: Icons.signal_cellular_alt_rounded,
            title: 'Мобильный интернет',
            value: c.playMobile,
            onChanged: c.setPlayMobile,
            active: c.metered,
          ),
          const SizedBox(height: 10),
          _Hint(
            detects
                ? 'Сейчас ${c.metered ? 'мобильный интернет' : 'Wi-Fi'}, играет ${qualityName(c.playNow)}. '
                      'Если сеть сменится, новое качество включится со следующего трека.'
                : 'Компьютер всегда играет в качестве для Wi-Fi и кабеля. '
                      'Качество для мобильного интернета пригодится на телефоне.',
          ),
        ] else ...[
          _QualityPick(icon: Icons.graphic_eq_rounded, title: 'Всегда', value: c.playManual, onChanged: c.setPlayManual),
          const SizedBox(height: 10),
          _Hint(qualityHint(c.playManual)),
        ],
        const SizedBox(height: 26),
        const _Label('Переходы между треками'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Плавные переходы'),
          subtitle: const _Hint(
            'Конец трека затихает, а следующий в это время набирает громкость. '
            'Треки альбома играют встык, как задумано.',
          ),
          value: c.crossfade,
          onChanged: c.setCrossfade,
        ),
        if (c.crossfade) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('Длительность', style: text.bodyMedium)),
              Text('${c.fade} с', style: text.titleMedium?.copyWith(color: context.status.accent)),
            ],
          ),
          Slider(
            min: 1,
            max: 12,
            divisions: 11,
            value: c.fade.toDouble().clamp(1, 12),
            label: '${c.fade} с',
            onChanged: (v) => c.setFade(v.round()),
          ),
        ],
        if (c.discordAvailable) ...[
          const SizedBox(height: 26),
          const _Label('Discord'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Показывать трек в Discord'),
            subtitle: const _Hint('Пока играет музыка, название и исполнитель видны в вашем статусе.'),
            value: c.discord,
            onChanged: c.setDiscord,
          ),
        ],
      ],
    );
  }
}

String qualityName(PlayQuality q) => switch (q) {
  PlayQuality.lossless => 'FLAC',
  PlayQuality.mp3 => 'MP3 320',
  PlayQuality.low => 'экономном качестве',
};

String qualityHint(PlayQuality q) => switch (q) {
  PlayQuality.lossless => 'FLAC без потерь до 24 бит / 192 кГц. Если у трека нет lossless, играет MP3 320.',
  PlayQuality.mp3 => 'MP3 320: почти не отличить на слух, а трафика в 3-5 раз меньше.',
  PlayQuality.low => 'Экономный режим для слабой связи: битрейт ниже, трафика меньше.',
};

class _QualityPick extends StatelessWidget {
  const _QualityPick({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.active = false,
  });

  final IconData icon;
  final String title;
  final PlayQuality value;
  final ValueChanged<PlayQuality> onChanged;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phone = isPhone(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: active ? context.status.accent : scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.bodyMedium)),
              if (active)
                Text('сейчас', style: TextStyle(fontSize: 12, color: context.status.accent)),
            ],
          ),
        ),
        SegmentedButton<PlayQuality>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: PlayQuality.lossless, label: Text(phone ? 'FLAC' : 'FLAC без потерь')),
            const ButtonSegment(value: PlayQuality.mp3, label: Text('MP3 320')),
            const ButtonSegment(value: PlayQuality.low, label: Text('Эконом')),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ],
    );
  }
}

class _Downloads extends StatelessWidget {
  const _Downloads({required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final phone = isPhone(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Label('Папка для загрузок'),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
          child: Row(
            children: [
              Icon(Icons.folder_rounded, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Tooltip(
                  message: c.dir,
                  child: Text(c.dir, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              IconButton(
                tooltip: 'Открыть папку',
                icon: const Icon(Icons.open_in_new_rounded, size: 20),
                onPressed: c.dir.isEmpty ? null : () => c.openFolder(c.dir),
              ),
              FilledButton.tonal(onPressed: c.chooseDir, child: const Text('Изменить')),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const _Label('Формат файлов'),
        SegmentedButton<Quality>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: Quality.lossless,
              icon: phone ? null : const Icon(Icons.graphic_eq_rounded),
              label: Text(phone ? 'FLAC' : 'FLAC (без потерь)'),
            ),
            ButtonSegment(
              value: Quality.mp3,
              icon: phone ? null : const Icon(Icons.music_note_rounded),
              label: const Text('MP3 320'),
            ),
          ],
          selected: {c.quality},
          onSelectionChanged: (s) => c.setQuality(s.first),
        ),
        const SizedBox(height: 8),
        _Hint(
          c.quality == Quality.lossless
              ? 'FLAC до 24 бит / 192 кГц. Если у трека нет lossless-версии, скачается MP3 320.'
              : 'MP3 лучшего доступного битрейта, файлы в 3-5 раз меньше FLAC.',
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            const Expanded(child: _Label('Одновременных загрузок')),
            Text('${c.concurrency}', style: text.titleMedium?.copyWith(color: context.status.accent)),
          ],
        ),
        Slider(
          min: 1,
          max: 8,
          divisions: 7,
          value: c.concurrency.toDouble().clamp(1, 8),
          label: '${c.concurrency}',
          onChanged: (v) => c.setConcurrency(v.round()),
        ),
        const _Hint(
          'Сколько треков качается параллельно во всех заданиях сразу. Меняется на лету, без остановки загрузок.',
        ),
      ],
    );
  }
}

class _Look extends StatelessWidget {
  const _Look({required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Label('Тема'),
        SegmentedButton<ThemeChoice>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: ThemeChoice.system,
              icon: phone ? null : const Icon(Icons.brightness_auto_rounded),
              label: const Text('Системная'),
            ),
            ButtonSegment(
              value: ThemeChoice.light,
              icon: phone ? null : const Icon(Icons.light_mode_rounded),
              label: const Text('Светлая'),
            ),
            ButtonSegment(
              value: ThemeChoice.dark,
              icon: phone ? null : const Icon(Icons.dark_mode_rounded),
              label: const Text('Тёмная'),
            ),
          ],
          selected: {c.theme},
          onSelectionChanged: (s) => c.setTheme(s.first),
        ),
      ],
    );
  }
}

class _About extends StatelessWidget {
  const _About({required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UpdateRow(c: c),
        const SizedBox(height: 20),
        const _Hint(
          'YAMP: открытый плеер для Яндекс Музыки по лицензии GPL-3.0. '
          'Неофициальный проект, не связан с компанией «Яндекс».',
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 12.5, height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}
