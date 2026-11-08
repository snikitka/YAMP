import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/android_core.dart';
import 'core/core.dart';
import 'core/fake_core.dart';
import 'desktop.dart';
import 'player/engine.dart';
import 'player/system_media.dart';
import 'state/controller.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final exe = Platform.resolvedExecutable;
  final Core core;
  final demo = args.contains('--demo') || const bool.fromEnvironment('YMD_DEMO');
  final engine = demo ? SilentEngine(tick: const Duration(milliseconds: 250)) : _engine();
  if (demo) {
    core = FakeCore();
  } else if (Platform.isAndroid) {
    core = AndroidCore();
  } else {
    final path = Platform.environment['YMCORE'] ?? ProcessCore.beside(exe);
    core = path == null ? _MissingCore() : await ProcessCore.start(path);
  }
  final controller = Controller(core, desktop: Desktop(args: args), engine: engine);
  if (!demo) SystemMedia(controller.player);
  runApp(YmdApp(controller: controller));
}

AudioEngine _engine() {
  try {
    MediaKitEngine.init();
    return MediaKitEngine();
  } catch (e) {
    return UnavailableEngine(
      Platform.isLinux
          ? 'Для воспроизведения нужна библиотека libmpv. Установите пакет libmpv2 или libmpv1 '
                '(Debian, Ubuntu), mpv-libs (Fedora) или mpv (Arch) и перезапустите YAMP'
          : 'Плеер не запустился: $e',
    );
  }
}

class _MissingCore implements Core {
  @override
  Stream<Event> get events => Stream.value({
        'type': 'fatal',
        'message': 'ядро ymcore не найдено рядом с программой',
      });

  @override
  void send(Map<String, Object?> command) {}

  @override
  Future<void> close() async {}
}
