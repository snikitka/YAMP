import 'core.dart';

const fakePairLink =
    'yamp://pair?f=fp&h=192.168.1.20&i=pc-demo&n=%D0%A0%D0%B0%D0%B1%D0%BE%D1%87%D0%B8%D0%B9+%D0%BD%D0%BE%D1%83%D1%82%D0%B1%D1%83%D0%BA&p=47391&s=secret';

class FakeRemote {
  FakeRemote(this._emit, this._later);

  final void Function(Event) _emit;
  final void Function(Duration, void Function()) _later;

  static const pcId = 'pc-demo';
  static const pcName = 'Рабочий ноутбук';

  static const _songs = [('Ветер', 'ДДТ', 301000), ('Перемен', 'Кино', 296000), ('Город золотой', 'Аквариум', 214000)];

  final phones = <Map<String, Object?>>[];
  var _pairing = false;
  var _scanning = false;
  var _paired = false;
  var _linked = false;
  var _pos = 0;
  var _playing = true;
  var _position = 42.0;
  var _volume = 0.6;
  var _shuffle = false;
  var _repeat = 'off';
  final _liked = <String>{};
  final List<Map<String, Object?>> sent = [];

  bool handle(Map<String, Object?> c) {
    switch (c['cmd']) {
      case 'remoteHost':
        _host();
      case 'remotePair':
        _pairing = true;
        _host();
      case 'remotePairCancel':
        _pairing = false;
        _host();
      case 'remoteUnpair':
        phones.removeWhere((p) => p['id'] == c['device']);
        _host();
      case 'remoteScan':
        _scanning = c['on'] == true;
        _devices();
      case 'remotePairLink':
        final link = '${c['link'] ?? ''}';
        if (!link.startsWith('yamp://pair')) {
          _link('', 'failed', message: 'это не код связывания YAMP');
          return true;
        }
        _link(pcId, 'pairing');
        _later(const Duration(milliseconds: 80), () {
          _paired = true;
          _devices();
          _online();
        });
      case 'remoteConnect':
        if (!_paired || c['device'] != pcId) return true;
        _link(pcId, 'connecting');
        _later(const Duration(milliseconds: 80), _online);
      case 'remoteDisconnect':
        if (_linked) _link(pcId, 'idle');
        _linked = false;
      case 'remoteForget':
        _paired = false;
        _linked = false;
        _devices();
      case 'remoteSend':
        final cmd = c['command'];
        if (cmd is Map<String, Object?> && _linked) _command(cmd);
      default:
        return false;
    }
    return true;
  }

  void pairPhone(String name) {
    if (!_pairing) return;
    _pairing = false;
    phones.add({'id': 'phone-${phones.length + 1}', 'name': name, 'online': true, 'added': 1762300000});
    _host();
  }

  void _host() => _emit({
    'type': 'remoteHost',
    'running': _pairing || phones.isNotEmpty,
    'name': 'DESKTOP-YAMP',
    if (_pairing) 'link': fakePairLink,
    if (_pairing) 'expiresIn': 300,
    'devices': phones,
  });

  void _devices() => _emit({
    'type': 'remoteDevices',
    'scanning': _scanning,
    'devices': [
      if (_paired || _scanning)
        {'id': pcId, 'name': pcName, 'login': 'ivan.petrov', 'host': '192.168.1.20', 'paired': _paired, 'online': true},
    ],
  });

  void _link(String id, String status, {String message = ''}) =>
      _emit({'type': 'remoteLink', 'id': id, 'name': pcName, 'status': status, 'message': message});

  void _online() {
    _linked = true;
    _link(pcId, 'online');
    _player();
    _queue();
    _playback();
  }

  Map<String, Object?> _track(int i) {
    final (title, artist, ms) = _songs[i % _songs.length];
    final id = 'r${i + 1}';
    return {'id': id, 'title': title, 'artist': artist, 'durationMs': ms, 'cover': '', 'liked': _liked.contains(id)};
  }

  void _remote(Map<String, Object?> event) => _emit({'type': 'remoteEvent', 'id': pcId, 'event': event});

  void _player() => _remote({
    'type': 'player',
    'track': _track(_pos),
    if (_pos + 1 < _songs.length) 'next': _track(_pos + 1),
    'pos': _pos,
    'count': _songs.length,
    'repeat': _repeat,
    'shuffle': _shuffle,
    'wave': false,
    'quality': 'lossless',
    'volume': _volume,
  });

  void _queue() => _remote({
    'type': 'queue',
    'pos': _pos,
    'tracks': [for (var i = 0; i < _songs.length; i++) _track(i)],
  });

  void _playback() => _remote({
    'type': 'playback',
    'track': _track(_pos)['id'],
    'playing': _playing,
    'position': _position,
    'volume': _volume,
  });

  void _jump(int to) {
    _pos = to.clamp(0, _songs.length - 1);
    _position = 0;
    _player();
    _queue();
    _playback();
  }

  void _command(Map<String, Object?> c) {
    sent.add(c);
    switch (c['cmd']) {
      case 'pause':
        _playing = false;
        _playback();
      case 'resume':
        _playing = true;
        _playback();
      case 'seek':
        _position = (c['position'] as num?)?.toDouble() ?? _position;
        _playback();
      case 'volume':
        _volume = (c['volume'] as num?)?.toDouble() ?? _volume;
        _playback();
      case 'playerNext':
        _jump(_pos + 1);
      case 'playerPrev':
        _jump(_pos - 1);
      case 'playerJump':
        _jump((c['pos'] as num?)?.toInt() ?? _pos);
      case 'play':
        _playing = true;
        _jump(((c['index'] as num?)?.toInt() ?? 0).clamp(0, _songs.length - 1));
      case 'wave':
        _playing = true;
        _jump(0);
      case 'playerShuffle':
        _shuffle = c['on'] == true;
        _player();
      case 'playerRepeat':
        _repeat = '${c['repeat'] ?? 'off'}';
        _player();
      case 'like':
        final id = '${c['track']}';
        if (c['on'] == true) {
          _liked.add(id);
        } else {
          _liked.remove(id);
        }
        _remote({'type': 'mark', 'track': id, 'liked': c['on'] == true, 'disliked': false});
        _player();
    }
  }
}
