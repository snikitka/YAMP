import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef Event = Map<String, dynamic>;

abstract class Core {
  Stream<Event> get events;
  void send(Map<String, Object?> command);
  Future<void> close();
}

class ProcessCore implements Core {
  ProcessCore._(this._process) {
    _process.stdin.encoding = utf8;
    _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_line, onDone: _ended);
    _stderrDone = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(_keepStderr)
        .catchError((Object _) {});
  }

  static const _stderrLimit = 16 << 10;

  final Process _process;
  final _events = StreamController<Event>();
  late final Future<void> _stderrDone;
  var _stderr = '';
  var _closed = false;

  static Future<ProcessCore> start(String exe) async {
    final process = await Process.start(exe, []);
    return ProcessCore._(process);
  }

  static String? beside(String windowExe) {
    final dir = File(windowExe).parent.path;
    for (final name in ['ymcore.exe', 'ymcore']) {
      final path = '$dir${Platform.pathSeparator}$name';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  @override
  Stream<Event> get events => _events.stream;

  void _line(String line) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (event is Event) _events.add(event);
  }

  void _keepStderr(String chunk) {
    _stderr += chunk;
    if (_stderr.length > _stderrLimit) _stderr = _stderr.substring(_stderr.length - _stderrLimit);
  }

  Future<void> _ended() async {
    final code = await _process.exitCode;
    await _stderrDone.timeout(const Duration(seconds: 2), onTimeout: () {});
    _events.add({'type': 'coreExited', 'code': code, 'stderr': _stderr});
    await _events.close();
  }

  @override
  void send(Map<String, Object?> command) {
    if (_closed) return;
    _process.stdin.writeln(jsonEncode(command));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _process.stdin.close();
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
  }
}
