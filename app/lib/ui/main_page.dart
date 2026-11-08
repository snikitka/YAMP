import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/controller.dart';
import 'downloads.dart';
import 'link_input.dart';
import 'log_dialog.dart';
import 'player/compact_player.dart';
import 'player/library_view.dart';
import 'player/mini_player.dart';
import 'player/now_playing.dart';
import 'remote_page.dart';
import 'search_view.dart';
import 'settings_dialog.dart';
import 'update_dialog.dart';
import 'widgets.dart';

class MainPage extends StatelessWidget {
  const MainPage({super.key, required this.c});

  final Controller c;

  void _close() => c.downloadsOpen.value = false;

  void _closePlayer() => c.player.panelOpen.value = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: c.compact,
      builder: (context, compact, page) => Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: compact,
            child: TickerMode(
              enabled: !compact,
              child: ExcludeFocus(excluding: compact, child: page!),
            ),
          ),
          if (compact) Positioned.fill(child: CompactPlayer(c: c)),
        ],
      ),
      child: _full(context),
    );
  }

  Widget _full(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([c.downloadsOpen, c.search, c.section, c.player.panelOpen, c.player.browsing]),
          builder: (context, _) {
            final open = c.downloadsOpen.value;
            final playerOpen = c.player.panelOpen.value;
            final inSearch = c.section.value == Section.search;
            final offHome = inSearch || (c.section.value == Section.collection && !c.player.browsing.value);
            final searching = inSearch && c.search.open;
            return LayoutBuilder(
              builder: (context, box) {
                final phone = box.maxWidth < phoneWidth;
                final Widget body = searching
                    ? FocusTraversalGroup(child: SearchView(c: c))
                    : phone && inSearch
                    ? const _SearchIntro()
                    : LibraryView(c: c, phone: phone, collection: c.section.value == Section.collection);
                return PopScope(
                  canPop: !open && !playerOpen && !searching && !(phone && offHome),
                  onPopInvokedWithResult: (didPop, _) {
                    if (didPop) return;
                    if (playerOpen) {
                      _closePlayer();
                    } else if (open) {
                      _close();
                    } else if (searching) {
                      c.search.close();
                    } else if (phone && offHome) {
                      c.home();
                    }
                  },
                  child: Stack(
                    children: [
                      ExcludeFocus(
                        excluding: open || playerOpen,
                        child: Column(
                          children: [
                            _Header(c: c, compact: box.maxWidth < 1080, phone: phone),
                            if (phone && inSearch)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                                child: LinkInput(c: c),
                              ),
                            Divider(height: 1, color: scheme.outlineVariant),
                            Expanded(child: body),
                            RemoteBar(c: c),
                            FocusTraversalGroup(
                              child: MiniPlayer(
                                p: c.player,
                                phone: phone,
                                onOpen: c.openPage,
                                onDownload: (link, q, title) => c.download(link, q, title: title),
                                onCompact: c.canCompact ? () => c.setCompact(true) : null,
                              ),
                            ),
                            if (phone) _SectionBar(c: c),
                          ],
                        ),
                      ),
                      if (playerOpen)
                        Positioned.fill(
                          child: _Reveal(
                            child: CallbackShortcuts(
                              bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closePlayer},
                              child: FocusScope(
                                autofocus: true,
                                child: NowPlaying(
                                  p: c.player,
                                  phone: phone,
                                  onOpen: c.openPage,
                                  onDownload: (link, q, title) => c.download(link, q, title: title),
                                  onCompact: c.canCompact ? () => c.setCompact(true) : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (open && phone)
                        Positioned.fill(
                          child: FocusScope(autofocus: true, child: DownloadsPanel(c: c)),
                        ),
                      if (open && !phone) ...[
                        Positioned.fill(
                          top: 73,
                          child: GestureDetector(
                            onTap: _close,
                            child: ColoredBox(color: Colors.black.withValues(alpha: 0.5)),
                          ),
                        ),
                        Positioned(
                          top: 80,
                          right: 12,
                          bottom: 12,
                          width: (box.maxWidth - 24).clamp(0, 440).toDouble(),
                          child: CallbackShortcuts(
                            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
                            child: FocusScope(autofocus: true, child: DownloadsPanel(c: c)),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = motion(context, const Duration(milliseconds: 280));
    if (d == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: d,
      curve: const Cubic(0.2, 0, 0, 1),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 24), child: child),
      ),
    );
  }
}

class _SectionBar extends StatelessWidget {
  const _SectionBar({required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      height: 64,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      selectedIndex: c.section.value.index,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      onDestinationSelected: (i) => switch (Section.values[i]) {
        Section.home => c.home(),
        Section.search => c.openSearch(),
        Section.collection => c.collection(),
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: 'Главная',
        ),
        NavigationDestination(
          icon: Icon(Icons.search_rounded),
          selectedIcon: Icon(Icons.manage_search_rounded),
          label: 'Поиск',
        ),
        NavigationDestination(
          icon: Icon(Icons.library_music_outlined),
          selectedIcon: Icon(Icons.library_music_rounded),
          label: 'Коллекция',
        ),
      ],
    );
  }
}

class _SearchIntro extends StatelessWidget {
  const _SearchIntro();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.travel_explore_rounded, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Найдите музыку', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                'Трек, альбом, исполнитель или ссылка на Яндекс Музыку',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _logout(BuildContext context, Controller c) async {
  final running = c.running;
  if (running > 0) {
    final ok = await confirm(
      context,
      title: 'Выйти из аккаунта?',
      body: 'Незавершённые загрузки остановятся: $running. Скачанные файлы останутся на диске.',
      action: 'Выйти',
    );
    if (!ok) return;
  }
  c.logout();
}

class _PhoneMenu extends StatelessWidget {
  const _PhoneMenu({required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AccountAvatar(account: c.account, size: 30),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(c.account.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (c.account.login.isNotEmpty && c.account.login != c.account.displayName)
                    Text(c.account.login, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                ],
              ),
              const SizedBox(width: 10),
              const PlusBadge(),
            ],
          ),
        ),
        const Divider(),
        if (c.desktop.controlsRemote)
          MenuItemButton(
            leadingIcon: const Icon(Icons.settings_remote_rounded),
            onPressed: () => openRemote(context, c),
            child: const Text('Пульт для компьютера'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.settings_rounded),
          onPressed: () => showSettingsDialog(context, c),
          child: const Text('Настройки'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.receipt_long_rounded),
          onPressed: () => showLogDialog(context, c),
          child: const Text('Журнал'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.verified_outlined),
          onPressed: c.recheck,
          child: const Text('Проверить подписку'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.logout_rounded),
          onPressed: () => _logout(context, c),
          child: const Text('Выйти'),
        ),
      ],
      builder: (context, menu, _) => IconButton(
        tooltip: 'Меню',
        icon: const Icon(Icons.more_vert_rounded),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.c, required this.compact, required this.phone});

  final Controller c;
  final bool compact, phone;

  @override
  Widget build(BuildContext context) {
    if (phone) {
      return SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.only(left: 14, right: 4),
          child: Row(
            children: [
              const BrandMark(size: 30),
              const SizedBox(width: 10),
              Text('YAMP', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const Spacer(),
              UpdateButton(c: c),
              DownloadsButton(c: c),
              _PhoneMenu(c: c),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      height: 72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Tooltip(
              message: 'Главная',
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: c.home,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Row(
                    children: [
                      const BrandMark(size: 34),
                      if (!compact) ...[
                        const SizedBox(width: 10),
                        Text(
                          'YAMP',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: compact ? 16 : 28),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: LinkInput(c: c),
                ),
              ),
            ),
            SizedBox(width: compact ? 12 : 24),
            UpdateButton(c: c),
            DownloadsButton(c: c),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Журнал',
              icon: const Icon(Icons.receipt_long_rounded),
              onPressed: () => showLogDialog(context, c),
            ),
            IconButton(
              tooltip: 'Настройки',
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => showSettingsDialog(context, c),
            ),
            const SizedBox(width: 6),
            _AccountPill(c: c, compact: compact),
          ],
        ),
      ),
    );
  }
}

class _AccountPill extends StatelessWidget {
  const _AccountPill({required this.c, required this.compact});

  final Controller c;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const shape = StadiumBorder();
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            c.account.login.isNotEmpty ? c.account.login : c.account.displayName,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        const Divider(),
        MenuItemButton(
          leadingIcon: const Icon(Icons.verified_outlined),
          onPressed: c.recheck,
          child: const Text('Проверить подписку'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.logout_rounded),
          onPressed: () => _logout(context, c),
          child: const Text('Выйти'),
        ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: compact ? c.account.displayName : 'Аккаунт',
        child: Material(
          color: scheme.surfaceContainerHigh,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: shape,
            onTap: () => menu.isOpen ? menu.close() : menu.open(),
            child: Padding(
              padding: EdgeInsets.fromLTRB(4, 4, compact ? 8 : 12, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AccountAvatar(account: c.account, size: 30),
                  if (!compact) ...[
                    const SizedBox(width: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        c.account.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  const PlusBadge(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
