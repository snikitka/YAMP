import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state/controller.dart';
import 'state/models.dart';
import 'theme.dart';
import 'ui/login_page.dart';
import 'ui/player/keys.dart';
import 'ui/main_page.dart';
import 'ui/update_dialog.dart';
import 'ui/widgets.dart';

class YmdApp extends StatefulWidget {
  const YmdApp({super.key, required this.controller});

  final Controller controller;

  @override
  State<YmdApp> createState() => _YmdAppState();
}

class _YmdAppState extends State<YmdApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<Notice>? _notices;
  StreamSubscription<UpdateInfo>? _offers;
  StreamSubscription<void>? _exits;
  var _offerPending = false;
  var _askingExit = false;
  late final AppLifecycleListener _lifecycle;

  Controller get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _notices = c.notices.listen(_showNotice);
    _offers = c.updateOffers.listen((_) {
      _offerPending = true;
      _offerUpdate();
    });
    _exits = c.exitRequests.listen((_) => _confirmExit());
    c.addListener(_offerUpdate);
    _lifecycle = AppLifecycleListener(onHide: c.player.savePosition, onDetach: c.player.savePosition);
    c.start();
  }

  Future<void> _confirmExit() async {
    final ctx = _navigator.currentContext;
    if (_askingExit || ctx == null) return;
    _askingExit = true;
    final ok = await confirm(
      ctx,
      title: 'Выйти из YAMP?',
      body: 'Незавершённые загрузки: ${c.running}. Они остановятся, готовые треки останутся.',
      action: 'Выйти',
    );
    _askingExit = false;
    if (ok) c.quit();
  }

  void _offerUpdate() {
    if (!_offerPending || !c.canDownload) return;
    final ctx = _navigator.currentContext;
    if (ctx == null || !ctx.mounted) return;
    _offerPending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ctx.mounted) showUpdateDialog(ctx, c);
    });
  }

  @override
  void dispose() {
    c.removeListener(_offerUpdate);
    _lifecycle.dispose();
    _notices?.cancel();
    _offers?.cancel();
    _exits?.cancel();
    super.dispose();
  }

  void _showNotice(Notice n) {
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    final ctx = messenger.context;
    final scheme = Theme.of(ctx).colorScheme;
    final (icon, color) = switch (n.kind) {
      NoticeKind.error => (Icons.error_rounded, scheme.error),
      NoticeKind.ok => (Icons.check_circle_rounded, ctx.status.success),
      NoticeKind.info => (Icons.info_rounded, scheme.primary),
    };
    final width = MediaQuery.sizeOf(ctx).width;
    final panel = c.downloadsOpen.value && width > 900;
    final phone = width < phoneWidth;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          width: panel || phone ? null : 460,
          margin: panel ? const EdgeInsets.fromLTRB(20, 0, 472, 16) : null,
          backgroundColor: scheme.surfaceContainerHighest,
          persist: false,
          duration: Duration(seconds: n.onAction == null ? 4 : 8),
          action: n.onAction == null
              ? null
              : SnackBarAction(label: n.action, textColor: ctx.status.accent, onPressed: n.onAction!),
          content: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(n.message, style: TextStyle(color: scheme.onSurface))),
            ],
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        return MaterialApp(
          title: 'YAMP',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: _messenger,
          navigatorKey: _navigator,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          builder: (context, child) => PlayerKeys(
            p: c.player,
            enabled: () => c.canDownload && !(_navigator.currentState?.canPop() ?? false),
            child: child ?? const SizedBox.shrink(),
          ),
          themeMode: switch (c.theme) {
            ThemeChoice.light => ThemeMode.light,
            ThemeChoice.dark => ThemeMode.dark,
            ThemeChoice.system => ThemeMode.system,
          },
          home: Builder(
            builder: (context) => AnimatedSwitcher(
              duration: motion(context, const Duration(milliseconds: 320)),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  scale: Tween(begin: 0.985, end: 1.0).animate(anim),
                  child: child,
                ),
              ),
              child: _screen(),
            ),
          ),
        );
      },
    );
  }

  Widget _screen() {
    if (c.fatal != null) return _Fatal(key: const ValueKey('fatal'), c: c);

    final restoring = c.account.status == AccountStatus.checking && c.account.login.isEmpty;
    if (!c.ready) return const _Splash(key: ValueKey('splash'));
    if (c.canDownload) return MainPage(key: const ValueKey('main'), c: c);
    if (restoring && !_loginShown) return const _Splash(key: ValueKey('splash'));
    _loginShown = true;
    return LoginPage(key: const ValueKey('login'), c: c);
  }

  var _loginShown = false;
}

class _Splash extends StatelessWidget {
  const _Splash({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandMark(size: 56),
            SizedBox(height: 24),
            SizedBox(width: 120, child: LinearProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

const releasesUrl = 'https://github.com/TheGreatPepix/YAMP/releases/latest';

class _Fatal extends StatelessWidget {
  const _Fatal({super.key, required this.c});

  final Controller c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 52, color: scheme.error),
                const SizedBox(height: 16),
                Text(c.fatal ?? '', textAlign: TextAlign.center, style: text.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Перезапустите YAMP. Если ошибка повторится, скачайте программу заново со страницы '
                  'релизов: настройки и вход сохранятся.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      autofocus: true,
                      onPressed: c.restart,
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      label: const Text('Перезапустить'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => c.openLink(releasesUrl),
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Страница релизов'),
                    ),
                    if (c.log.value.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => Clipboard.setData(ClipboardData(text: c.log.value)),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Скопировать журнал'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
