import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'core.dart';

class AndroidCore implements Core {
  AndroidCore() {
    _sub = const EventChannel('yamp/core/events').receiveBroadcastStream().listen(_event);
  }

  static const _method = MethodChannel('yamp/core');

  final _events = StreamController<Event>();
  late final StreamSubscription<dynamic> _sub;

  @override
  Stream<Event> get events => _events.stream;

  void _event(dynamic line) {
    if (line is! String) return;
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (event is Event) _events.add(event);
  }

  @override
  void send(Map<String, Object?> command) {
    _method.invokeMethod<void>('send', jsonEncode(command));
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    await _events.close();
  }
}
