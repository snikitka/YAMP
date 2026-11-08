import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/core.dart';
import '../desktop.dart';
import '../player/engine.dart';
import 'models.dart';
import 'player.dart';
import 'presence.dart';
import 'remote.dart';
import 'search.dart';

enum Section { home, search, collection }

class Controller extends ChangeNotifier {
  Controller(this.core, {Desktop? desktop, AudioEngine? engine})
    : desktop = desktop ?? Desktop(),
      player = PlayerState(core.send, engine ?? SilentEngine()) {
    _sub = core.events.listen(_receive);
    player.onBlocked = (message) => _notices.add(Notice(message, kind: NoticeKind.error));
    player.onShare = share;
    player.divert = remote.divert;
    remote.onDiverted = (sent) => _notices.add(
      sent
          ? Notice('Включаю на компьютере «${remote.linkName}»', kind: NoticeKind.ok)
          : Notice('Нет связи с компьютером «${remote.linkName}», подключаюсь снова', kind: NoticeKind.error),
    );
    player.panelOpen.addListener(() {
      if (player.panelOpen.value) downloadsOpen.value = false;
    });
    downloadsOpen.addListener(() {
      if (downloadsOpen.value) player.panelOpen.value = false;
    });
    this.desktop.listen(exit: _trayExit);
    this.desktop.watchNetwork((metered) => send({'cmd': 'network', 'metered': metered}));
    _presence = Presence(player, send);
  }

  final Core core;
  final Desktop desktop;
  late final StreamSubscription<Event> _sub;
  late final Presence _presence;

  final _notices = StreamController<Notice>.broadcast();
  Stream<Notice> get notices => _notices.stream;

  final _updateOffers = StreamController<UpdateInfo>.broadcast();
  Stream<UpdateInfo> get updateOffers => _updateOffers.stream;

  final _exitRequests = StreamController<void>.broadcast();
  Stream<void> get exitRequests => _exitRequests.stream;

  var ready = false;
  String? fatal;

  var account = const Account();
  var dir = '';
  var theme = ThemeChoice.dark;
  var quality = Quality.lossless;
  var concurrency = 4;
  var version = '';
  var discord = true;
  var discordAvailable = false;
  var playAuto = true;
  var playManual = PlayQuality.lossless;
  var playWifi = PlayQuality.lossless;
  var playMobile = PlayQuality.mp3;
  var playNow = PlayQuality.lossless;
  var metered = false;
  var crossfade = true;
  var fade = 6;

  UpdateInfo? update;
  var checkingUpdate = false;
  var updating = false;
  final updateProgress = ValueNotifier<double?>(null);

  final downloadsOpen = ValueNotifier(false);
  final compact = ValueNotifier(false);
  final pinned = ValueNotifier(false);
  final section = ValueNotifier(Section.home);
  final PlayerState player;
  late final search = SearchState(send);
  late final remote = RemoteState(send);

  final _jobs = <int, Job>{};
  List<Job> get jobs => _jobs.values.toList().reversed.toList();

  final stats = ValueNotifier(const Stats());

  final log = ValueNotifier('');
  final device = ValueNotifier(const DeviceLogin());

  bool get canDownload => account.status == AccountStatus.ok;

  bool get downloading => _jobs.values.any((j) => !j.finished);

  int get running => _jobs.values.where((j) => !j.finished).length;

  void restart() => desktop.restart();

  void _trayExit() {
    if (!downloading) {
      quit();
      return;
    }
    desktop.showWindow();
    _exitRequests.add(null);
  }

  void quit() {
    player.savePosition();
    if (fatal != null) {
      desktop.quit();
    } else {
      send({'cmd': 'exit'});
    }
  }

  void start() => send({'cmd': 'ready'});

  void send(Map<String, Object?> command) => core.send(command);

  void login(String token) => send({'cmd': 'login', 'token': token.trim()});

  void startDeviceLogin() {
    device.value = const DeviceLogin(status: DeviceStatus.requesting);
    send({'cmd': 'deviceLogin'});
  }

  void cancelDeviceLogin() {
    device.value = const DeviceLogin();
    send({'cmd': 'deviceCancel'});
  }

  void recheck() => send({'cmd': 'recheck'});

  void logout() {
    search.close();
    device.value = const DeviceLogin();
    send({'cmd': 'logout'});
  }

  Future<void> download(String link, Quality quality, {String title = ''}) async {
    if (link.isEmpty) return;
    if (!await desktop.storageGranted()) {
      _notices.add(
        Notice(
          'Нужен доступ к файлам, чтобы сохранять музыку',
          kind: NoticeKind.error,
          action: 'Разрешить',
          onAction: desktop.requestStorage,
        ),
      );
      return;
    }
    send({'cmd': 'download', 'link': link, 'quality': quality.name});
    final format = quality == Quality.lossless ? 'FLAC' : 'MP3 320';
    final what = title.isEmpty ? '' : ' «$title»';
    _notices.add(Notice('Скачиваю$what в $format', action: 'Загрузки', onAction: () => downloadsOpen.value = true));
  }

  void openLinks(String text) {
    final links = splitLinks(text);
    if (links.isEmpty) return;
    final link = links.first;
    search.close();
    if (_trackLink.hasMatch(link)) {
      player.play(link);
    } else {
      openPage(link);
    }
    if (links.length > 1) _notices.add(const Notice('Открыл первую ссылку из вставленных'));
  }

  static final _trackLink = RegExp(r'/track/\d+|^\d+$');

  void cancel(int id) => send({'cmd': 'cancel', 'id': id});

  void cancelAll() => send({'cmd': 'cancel', 'id': 0});

  void retry(int id) => send({'cmd': 'retry', 'id': id});

  void remove(int id) => send({'cmd': 'remove', 'id': id});

  void clearFinished() => send({'cmd': 'remove', 'id': 0});

  void setTheme(ThemeChoice t) {
    theme = t;
    send({'cmd': 'prefs', 'theme': t.name});
    notifyListeners();
  }

  void setDir(String d) {
    dir = d;
    send({'cmd': 'prefs', 'dir': d});
    notifyListeners();
  }

  void setPlayAuto(bool on) {
    playAuto = on;
    send({'cmd': 'playQuality', 'auto': on});
    notifyListeners();
  }

  void setPlayManual(PlayQuality q) {
    playManual = q;
    send({'cmd': 'playQuality', 'auto': false, 'quality': q.name});
    notifyListeners();
  }

  void setPlayWifi(PlayQuality q) {
    playWifi = q;
    send({'cmd': 'playQuality', 'wifi': q.name});
    notifyListeners();
  }

  void setPlayMobile(PlayQuality q) {
    playMobile = q;
    send({'cmd': 'playQuality', 'mobile': q.name});
    notifyListeners();
  }

  void setQuality(Quality q) {
    quality = q;
    send({'cmd': 'prefs', 'quality': q.name});
    notifyListeners();
  }

  void setConcurrency(int n) {
    concurrency = n;
    send({'cmd': 'prefs', 'concurrency': n});
    notifyListeners();
  }

  static const compactSize = Size(380, 168);

  bool get canCompact => desktop.canCompact;

  void setCompact(bool on) {
    if (compact.value == on) return;
    if (!on) pinned.value = false;
    compact.value = on;
    desktop.compact(on, width: compactSize.width.round(), height: compactSize.height.round());
  }

  void togglePin() {
    pinned.value = !pinned.value;
    desktop.pin(pinned.value);
  }

  void _applyFade() => player.crossfade = crossfade ? Duration(seconds: fade) : Duration.zero;

  void setCrossfade(bool on) {
    crossfade = on;
    _applyFade();
    send({'cmd': 'prefs', 'crossfade': on});
    notifyListeners();
  }

  void setFade(int seconds) {
    if (fade == seconds) return;
    fade = seconds;
    _applyFade();
    send({'cmd': 'prefs', 'fade': seconds});
    notifyListeners();
  }

  void setDiscord(bool on) {
    discord = on;
    send({'cmd': 'prefs', 'discord': on});
    notifyListeners();
  }

  void checkUpdate() {
    checkingUpdate = true;
    send({'cmd': 'checkUpdate'});
    notifyListeners();
  }

  void applyUpdate() {
    if (updating) return;
    updating = true;
    updateProgress.value = null;
    send({'cmd': 'applyUpdate'});
    notifyListeners();
  }

  void _onUpdate(UpdateInfo u) {
    checkingUpdate = false;
    update = u;
    if (u.quiet) {
      if (u.available) _updateOffers.add(u);
    } else if (u.error.isNotEmpty) {
      _notices.add(Notice('Не удалось проверить обновления: ${u.error}', kind: NoticeKind.error));
    } else if (!u.available) {
      _notices.add(Notice('У вас последняя версия ${u.current}', kind: NoticeKind.ok));
    }
  }

  void _onUpdating(Event ev) {
    final error = ev['error'];
    if (error != null) {
      updating = false;
      updateProgress.value = null;
      _notices.add(Notice('Не удалось обновить YAMP: $error', kind: NoticeKind.error));
      return;
    }
    if (ev['installer'] == true) {
      updating = false;
      updateProgress.value = null;
      _notices.add(Notice('Обновление скачано. Подтвердите установку в окне Android', kind: NoticeKind.info));
      return;
    }
    updating = true;
    final done = (ev['done'] as num?)?.toDouble() ?? 0;
    final total = (ev['total'] as num?)?.toDouble() ?? 0;
    updateProgress.value = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
  }

  Future<void> openFolder(String path) async {
    if (!await desktop.open(path)) _folderMissing(path);
  }

  Future<void> share(String link) async {
    if (link.isEmpty || await desktop.share(link)) return;
    await Clipboard.setData(ClipboardData(text: link));
    _notices.add(const Notice('Ссылка скопирована', kind: NoticeKind.ok));
  }

  Future<void> reveal(String file) async {
    if (!await desktop.reveal(file)) _folderMissing(file);
  }

  void _folderMissing(String path) => _notices.add(
    Notice('Не нашлось приложения, чтобы открыть папку. Файлы лежат здесь: $path', kind: NoticeKind.error),
  );

  Future<void> chooseDir() async {
    try {
      final path = await desktop.pickFolder(dir);
      if (path != null && path.isNotEmpty) setDir(path);
    } on PlatformException catch (e) {
      _notices.add(Notice(e.message ?? 'Не удалось выбрать папку', kind: NoticeKind.error));
    }
  }

  void openLink(String url) => desktop.open(url);

  void clearLog() => log.value = '';

  void _appendLog(String text) {
    var s = log.value + text;
    const limit = 200000;
    if (s.length > limit) {
      var cut = s.length - limit * 3 ~/ 4;
      final nl = s.indexOf('\n', cut);
      if (nl >= 0) cut = nl + 1;
      s = s.substring(cut);
    }
    log.value = s;
  }

  void home() {
    section.value = Section.home;
    player.panelOpen.value = false;
    player.browseTo(sourceHome, fromLibrary: true);
    player.browsing.value = false;
  }

  void collection() {
    section.value = Section.collection;
    player.browsing.value = false;
    player.loadLibrary();
  }

  void openSearch() => section.value = Section.search;

  void openPage(String source) {
    if (source.isEmpty) return;
    final fresh = section.value == Section.search || (!player.browsing.value && player.browse.value != sourceHome);
    player.panelOpen.value = false;
    if (section.value == Section.search) section.value = Section.home;
    player.browseTo(source, fromLibrary: fresh);
  }

  void openHit(SearchHit hit) {
    if (hit.kind == ReleaseKind.track) {
      player.play(hit.link);
      return;
    }
    openPage(hit.link);
  }

  void _receive(Event ev) {
    switch (ev['type']) {
      case 'player' || 'queue' || 'playerFormat' || 'mark' || 'library' || 'home' || 'tracks' || 'lyrics':
        player.receive(ev);
        return;
      case 'remoteHost' || 'remoteDevices' || 'remoteLink' || 'remoteEvent':
        remote.receive(ev);
        return;
      case 'remote':
        _remoteAction(ev);
        return;
      case 'state':
        dir = '${ev['dir'] ?? ''}';
        theme = switch ('${ev['theme']}') {
          'light' => ThemeChoice.light,
          'dark' => ThemeChoice.dark,
          _ => ThemeChoice.system,
        };
        quality = ev['quality'] == 'mp3' ? Quality.mp3 : Quality.lossless;
        concurrency = (ev['concurrency'] as num?)?.toInt() ?? concurrency;
        version = '${ev['version'] ?? ''}';
        discord = ev['discord'] != false;
        discordAvailable = ev['discordAvailable'] == true;
        PlayQuality q(Object? v, PlayQuality or) => PlayQuality.values.asNameMap()['$v'] ?? or;
        playAuto = ev['playAuto'] != false;
        playManual = q(ev['playManual'], PlayQuality.lossless);
        playWifi = q(ev['playWifi'], PlayQuality.lossless);
        playMobile = q(ev['playMobile'], PlayQuality.mp3);
        playNow = q(ev['playQuality'], playManual);
        metered = ev['metered'] == true;
        crossfade = ev['crossfade'] != false;
        fade = (ev['fade'] as num?)?.toInt() ?? fade;
        _applyFade();
        if (ev['log'] is String) log.value = ev['log'] as String;
        ready = true;
      case 'account':
        account = Account.fromJson(ev);
      case 'deviceLogin':
        if (device.value.status == DeviceStatus.idle && ev['status'] != 'done') return;
        device.value = ev['status'] == 'done' ? const DeviceLogin() : DeviceLogin.fromJson(ev, DateTime.now());
        return;
      case 'job':
        final id = (ev['id'] as num).toInt();
        final existing = _jobs[id];
        if (existing != null) {
          existing.apply(ev);
          return;
        }
        _jobs[id] = Job(id)..apply(ev);
      case 'jobRemoved':
        _jobs.remove((ev['id'] as num).toInt())?.dispose();
      case 'search':
        search.receive(ev);
        return;
      case 'stats':
        stats.value = Stats.fromJson(ev);
        return;
      case 'log':
        _appendLog('${ev['text'] ?? ''}');
        return;
      case 'notice':
        _notices.add(
          Notice(
            '${ev['message'] ?? ''}',
            kind: switch (ev['kind']) {
              'error' => NoticeKind.error,
              'ok' => NoticeKind.ok,
              _ => NoticeKind.info,
            },
          ),
        );
        return;
      case 'update':
        _onUpdate(UpdateInfo.fromJson(ev));
      case 'updating':
        final was = updating;
        _onUpdating(ev);
        if (was == updating) return;
      case 'exit':
        desktop.quit();
        return;
      case 'fatal':
        fatal = '${ev['message'] ?? ''}';
      case 'coreExited':
        fatal ??= 'Ядро остановилось (код ${ev['code']}).';
        final stderr = '${ev['stderr'] ?? ''}'.trim();
        if (stderr.isNotEmpty) _appendLog('Вывод ядра перед остановкой:\n$stderr\n');
      default:
        return;
    }
    notifyListeners();
  }

  void _remoteAction(Event ev) {
    switch (ev['action']) {
      case 'pause':
        player.pause();
      case 'resume':
        player.resume();
      case 'seek':
        if (ev['position'] case final num s) player.seek(Duration(milliseconds: (s * 1000).round()));
      case 'volume':
        if (ev['volume'] case final num v) {
          player.previewVolume(v.toDouble());
          player.commitVolume();
        }
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _notices.close();
    _updateOffers.close();
    _exitRequests.close();
    updateProgress.dispose();
    for (final j in _jobs.values) {
      j.dispose();
    }
    search.dispose();
    remote.dispose();
    downloadsOpen.dispose();
    compact.dispose();
    pinned.dispose();
    section.dispose();
    _presence.dispose();
    player.dispose();
    stats.dispose();
    log.dispose();
    device.dispose();
    super.dispose();
  }
}
