import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/controller.dart';
import '../state/models.dart';
import '../theme.dart';
import 'widgets.dart';

const oauthUrl =
    'https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d';
const plusUrl = 'https://plus.yandex.ru/';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.c});

  final Controller c;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _token = TextEditingController();
  var _obscure = true;
  var _manual = false;

  Controller get c => widget.c;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  bool _rechecking(Account acc) => acc.status == AccountStatus.checking && acc.login.isNotEmpty;

  void _submit() {
    if (_token.text.trim().isEmpty) return;
    c.login(_token.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final acc = c.account;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -1.1),
            radius: 0.9,
            colors: [brandYellow.withValues(alpha: 0.07), scheme.surface],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: BrandMark(size: 64)),
                  const SizedBox(height: 20),
                  Text(
                    'YAMP',
                    textAlign: TextAlign.center,
                    style: text.headlineSmall,
                  ),
                  Text(
                    'Yet Another Music Player',
                    textAlign: TextAlign.center,
                    style: text.labelLarge?.copyWith(color: context.status.accent, letterSpacing: 0.4),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Треки, альбомы и дискографии в FLAC и MP3\nдля подписчиков Яндекс Плюс',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
                  ),
                  const SizedBox(height: 28),
                  Panel(
                    padding: const EdgeInsets.all(24),
                    child: AnimatedSize(
                      duration: motion(context, const Duration(milliseconds: 220)),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: _rechecking(acc) || acc.status == AccountStatus.noplus
                          ? _noPlus(acc)
                          : _manual
                              ? _form(acc)
                              : _device(acc),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text.rich(
                    TextSpan(
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(Icons.lock_outline_rounded, size: 14, color: scheme.onSurfaceVariant),
                          ),
                        ),
                        TextSpan(
                          text: Platform.isWindows
                              ? 'Токен хранится только на этом компьютере, зашифрованным (Windows DPAPI)'
                              : Platform.isAndroid
                                  ? 'Токен хранится только на этом устройстве, в памяти приложения'
                                  : 'Токен хранится только на этом компьютере, в файле настроек, '
                                      'доступном только вашему пользователю',
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _device(Account acc) {
    return ValueListenableBuilder(
      valueListenable: c.device,
      builder: (context, d, _) => d.status == DeviceStatus.code && acc.status != AccountStatus.checking
          ? _DeviceCode(key: ValueKey(d.code), c: c, login: d)
          : _deviceStart(acc, d),
    );
  }

  Widget _deviceStart(Account acc, DeviceLogin d) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final checking = acc.status == AccountStatus.checking;
    final requesting = d.status == DeviceStatus.requesting;
    return Column(
      key: const ValueKey('device'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Вход', style: text.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Войдите через Яндекс. Мы проверим, что у аккаунта есть Плюс.',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (d.status == DeviceStatus.expired) ...[
          const SizedBox(height: 12),
          _Banner(
            icon: Icons.timer_off_outlined,
            color: context.status.warning,
            text: 'Код истёк. Получите новый, это займёт пару секунд.',
          ),
        ],
        if (d.status == DeviceStatus.error && d.message.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Banner(icon: Icons.error_outline_rounded, color: scheme.error, text: d.message),
        ],
        if (acc.status == AccountStatus.error && acc.message.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Banner(icon: Icons.error_outline_rounded, color: scheme.error, text: acc.message),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: checking || requesting ? null : c.startDeviceLogin,
          icon: checking || requesting
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.onSurfaceVariant),
                )
              : const Icon(Icons.login_rounded, size: 18),
          label: Text(switch ((checking, requesting, d.status)) {
            (true, _, _) => 'Проверяю подписку…',
            (_, true, _) => 'Получаю код…',
            (_, _, DeviceStatus.expired) => 'Получить новый код',
            _ => 'Войти через Яндекс',
          }),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: checking ? null : () => setState(() => _manual = true),
          child: const Text('Вставить токен вручную'),
        ),
      ],
    );
  }

  Widget _form(Account acc) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final checking = acc.status == AccountStatus.checking;
    return Column(
      key: const ValueKey('form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Вход по токену', style: text.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Если вход по коду не подходит, вставьте OAuth-токен Яндекс Музыки. '
          'Мы проверим, что у аккаунта есть Плюс.',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _token,
          obscureText: _obscure,
          enabled: !checking,
          autofocus: true,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: 'Токен или адрес со страницы входа',
            prefixIcon: const Icon(Icons.key_rounded),
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Показать' : 'Скрыть',
              icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        if (acc.status == AccountStatus.error && acc.message.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Banner(icon: Icons.error_outline_rounded, color: scheme.error, text: acc.message),
        ],
        const SizedBox(height: 20),
        ListenableBuilder(
          listenable: _token,
          builder: (context, _) => FilledButton(
            onPressed: checking || _token.text.trim().isEmpty ? null : _submit,
            child: checking
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(width: 12),
                      const Text('Проверяю подписку…'),
                    ],
                  )
                : const Text('Войти'),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => c.openLink(oauthUrl),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('Получить токен'),
        ),
        const SizedBox(height: 14),
        _Steps(
          steps: const [
            'Нажмите «Получить токен» и войдите в аккаунт Яндекса.',
            'Браузер откроет страницу с длинным адресом. Скопируйте его целиком.',
            'Вставьте адрес в поле выше: токен из него извлечётся сам.',
          ],
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: checking ? null : () => setState(() => _manual = false),
          child: const Text('Войти по коду'),
        ),
      ],
    );
  }

  Widget _noPlus(Account acc) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('noplus'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            AccountAvatar(account: acc, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(acc.displayName, style: text.titleMedium, overflow: TextOverflow.ellipsis),
                  if (acc.login.isNotEmpty && acc.login != acc.displayName)
                    Text(
                      acc.login,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _Banner(
          icon: Icons.workspace_premium_outlined,
          color: context.status.warning,
          text: 'У этого аккаунта нет подписки Яндекс Плюс. '
              'Скачивание доступно только с активной подпиской.',
        ),
        const SizedBox(height: 20),
        DecoratedBox(
          decoration: BoxDecoration(gradient: plusGradient, borderRadius: BorderRadius.circular(14)),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              shadowColor: Colors.transparent,
            ),
            onPressed: () => c.openLink(plusUrl),
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('Оформить Плюс'),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _rechecking(acc) ? null : c.recheck,
                icon: _rechecking(acc)
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Проверить снова'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: c.logout,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('Другой аккаунт'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DeviceCode extends StatefulWidget {
  const _DeviceCode({super.key, required this.c, required this.login});

  final Controller c;
  final DeviceLogin login;

  @override
  State<_DeviceCode> createState() => _DeviceCodeState();
}

class _DeviceCodeState extends State<_DeviceCode> {
  Timer? _tick;
  Timer? _copiedReset;
  var _copied = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _copiedReset?.cancel();
    super.dispose();
  }

  String get _left {
    final e = widget.login.expiresAt;
    if (e == null) return '';
    final s = e.difference(DateTime.now()).inSeconds.clamp(0, 3600);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String get _spaced {
    final code = widget.login.code;
    return code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.login.code));
    setState(() => _copied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final d = widget.login;
    final left = _left;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Подтвердите вход', style: text.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Откройте ${d.host} и введите код:',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: SelectableText(
            _spaced,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cascadia Mono',
              fontFamilyFallback: const ['Consolas', 'monospace'],
              fontSize: 30,
              letterSpacing: 6,
              fontWeight: FontWeight.w600,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          autofocus: true,
          onPressed: () => widget.c.openLink(d.url),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: Text('Открыть ${d.host}'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _copy,
          icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 18),
          label: Text(_copied ? 'Код скопирован' : 'Скопировать код'),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                left.isEmpty ? 'Жду подтверждения' : 'Жду подтверждения, код действует $left',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextButton(onPressed: widget.c.cancelDeviceLogin, child: const Text('Отмена')),
      ],
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, s) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: context.status.accent),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s,
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
