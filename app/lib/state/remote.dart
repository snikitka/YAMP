import 'dart:async';

import 'package:flutter/foundation.dart';

import 'player.dart';

enum LinkStatus { idle, pairing, connecting, online, offline, failed }

String _s(Object? v) => v == null ? '' : '$v';

int _i(Object? v) => (v as num?)?.toInt() ?? 0;

class RemoteDevice {
  const RemoteDevice({
    required this.id,
    this.name = '',
    this.login = '',
    this.host = '',
    this.paired = false,
    this.online = false,
  });

  factory RemoteDevice.fromJson(Map<String, dynamic> j) => RemoteDevice(
    id: _s(j['id']),
    name: _s(j['name']),
    login: _s(j['login']),
    host: _s(j['host']),
    paired: j['paired'] == true,
    online: j['online'] == true,
  );

  final String id, name, login, host;
  final bool paired, online;

  String get title => name.isEmpty ? 'Компьютер' : name;
}

class PairedPhone {
  const PairedPhone({required this.id, this.name = '', this.online = false, this.added});

  factory PairedPhone.fromJson(Map<String, dynamic> j) => PairedPhone(
    id: _s(j['id']),
    name: _s(j['name']),
    online: j['online'] == true,
    added: _i(j['added']) > 0 ? DateTime.fromMillisecondsSinceEpoch(_i(j['added']) * 1000) : null,
  );

  final String id, name;
  final bool online;
  final DateTime? added;
}

List<PlayTrack> _tracks(Object? v) => [
  for (final t in (v as List? ?? const []))
    if (t is Map<String, dynamic>) PlayTrack.fromJson(t),
];

class RemoteState extends ChangeNotifier {
  RemoteState(this._send, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final void Function(Map<String, Object?>) _send;
  final DateTime Function() _clock;

  var hostRunning = false;
  var hostName = '';
  var hostError = '';
  var pairLink = '';
  DateTime? pairUntil;
  var phones = const <PairedPhone>[];

  void openHost() => _send({'cmd': 'remoteHost'});

  void startPairing() {
    hostError = '';
    _send({'cmd': 'remotePair'});
    notifyListeners();
  }

  void stopPairing() {
    pairLink = '';
    pairUntil = null;
    _send({'cmd': 'remotePairCancel'});
  }

  void unpair(PairedPhone p) => _send({'cmd': 'remoteUnpair', 'device': p.id});

  var devices = const <RemoteDevice>[];
  var scanning = false;
  var scanError = '';
  var linkId = '';
  var linkName = '';
  var status = LinkStatus.idle;
  var linkMessage = '';

  bool get connected => status == LinkStatus.online;

  var target = false;

  void Function(bool sent)? onDiverted;

  bool get targeting => target && linkId.isNotEmpty;

  void browse() {
    if (linkId.isEmpty) return;
    target = true;
    notifyListeners();
  }

  bool divert(List<Map<String, Object?>> commands) {
    if (!targeting) return false;
    if (connected) {
      for (final c in commands) {
        _command(c);
      }
    }
    onDiverted?.call(connected);
    return true;
  }

  bool get busy => status == LinkStatus.pairing || status == LinkStatus.connecting;

  void scan(bool on) => _send({'cmd': 'remoteScan', 'on': on});

  void pair(String link, {String name = ''}) {
    linkMessage = '';
    status = LinkStatus.pairing;
    _send({'cmd': 'remotePairLink', 'link': link, 'name': name});
    notifyListeners();
  }

  void connect(RemoteDevice d) {
    if (!d.paired) return;
    _reset();
    linkId = d.id;
    linkName = d.title;
    linkMessage = '';
    status = LinkStatus.connecting;
    _send({'cmd': 'remoteConnect', 'device': d.id});
    notifyListeners();
  }

  void disconnect() {
    _send({'cmd': 'remoteDisconnect'});
    _reset();
    linkId = '';
    target = false;
    status = LinkStatus.idle;
    notifyListeners();
  }

  void forget(RemoteDevice d) {
    _send({'cmd': 'remoteForget', 'device': d.id});
    if (d.id == linkId) {
      _reset();
      linkId = '';
      target = false;
      status = LinkStatus.idle;
    }
    devices = [
      for (final x in devices)
        if (x.id != d.id) x,
    ];
    notifyListeners();
  }

  PlayTrack? track;
  PlayTrack? next;
  var art = '';
  var pos = 0;
  var count = 0;
  var repeat = Repeat.off;
  var shuffle = false;
  var wave = false;
  var loading = false;
  var playing = false;
  var volume = 0.8;
  var format = '';
  PlaySource? source;
  var queue = const <PlayTrack>[];
  final _marks = <String, (bool, bool)>{};
  final position = ValueNotifier(Duration.zero);

  var _base = Duration.zero;
  DateTime? _anchor;
  Timer? _ticker;
  DateTime? _volumeHeld;
  DateTime? _volumeSent;
  Timer? _volumeTimer;

  static const _tick = Duration(milliseconds: 250);
  static const _volumeEvery = Duration(milliseconds: 120);
  static const _volumeHold = Duration(seconds: 1);

  Duration get duration => track?.duration ?? Duration.zero;

  bool liked(PlayTrack t) => _marks[t.id]?.$1 ?? t.liked;

  bool disliked(PlayTrack t) => _marks[t.id]?.$2 ?? t.disliked;

  bool get hasTrack => track != null;

  Duration get at => _now();

  void _reset() {
    track = null;
    next = null;
    art = '';
    queue = const [];
    format = '';
    playing = false;
    _marks.clear();
    _setBase(Duration.zero);
  }

  Duration _now() {
    var at = _base;
    final anchor = _anchor;
    if (playing && anchor != null) at += _clock().difference(anchor);
    final total = duration;
    if (total > Duration.zero && at > total) at = total;
    return at < Duration.zero ? Duration.zero : at;
  }

  void _setBase(Duration at) {
    _base = at;
    _anchor = _clock();
    position.value = _now();
    _ticker?.cancel();
    _ticker = null;
    if (playing && connected) _ticker = Timer.periodic(_tick, (_) => position.value = _now());
  }

  void _command(Map<String, Object?> c) {
    if (connected) _send({'cmd': 'remoteSend', 'command': c});
  }

  void togglePlay() {
    if (!hasTrack) return;
    final at = _now();
    playing = !playing;
    _command({'cmd': playing ? 'resume' : 'pause'});
    _setBase(at);
    notifyListeners();
  }

  void nextTrack() => _command({'cmd': 'playerNext', 'track': ?track?.id});

  void previousTrack() => _command({'cmd': 'playerPrev', 'track': ?track?.id});

  void jump(int index) => _command({'cmd': 'playerJump', 'pos': index});

  void seek(Duration to) {
    _command({'cmd': 'seek', 'position': to.inMilliseconds / 1000});
    _setBase(to);
  }

  void like(PlayTrack t, bool on) {
    _marks[t.id] = (on, on ? false : disliked(t));
    _command({'cmd': 'like', 'track': t.id, 'on': on});
    notifyListeners();
  }

  void dislike(PlayTrack t, bool on) {
    _marks[t.id] = (on ? false : liked(t), on);
    _command({'cmd': 'dislike', 'track': t.id, 'on': on});
    notifyListeners();
  }

  void cycleRepeat() {
    final options = wave ? const [Repeat.off, Repeat.one] : Repeat.values;
    final i = options.indexOf(repeat);
    _command({'cmd': 'playerRepeat', 'repeat': options[(i + 1) % options.length].name});
  }

  void toggleShuffle() => _command({'cmd': 'playerShuffle', 'on': !shuffle});

  void setVolume(double v, {bool done = false}) {
    volume = v.clamp(0.0, 1.0);
    final now = _clock();
    _volumeHeld = now;
    _volumeTimer?.cancel();
    final sent = _volumeSent;
    if (done || sent == null || now.difference(sent) >= _volumeEvery) {
      _volumeSent = now;
      _command({'cmd': 'volume', 'volume': volume});
    } else {
      _volumeTimer = Timer(_volumeEvery, () {
        _volumeSent = _clock();
        _command({'cmd': 'volume', 'volume': volume});
      });
    }
    notifyListeners();
  }

  bool receive(Map<String, dynamic> ev) {
    switch (ev['type']) {
      case 'remoteHost':
        hostRunning = ev['running'] == true;
        hostName = _s(ev['name']);
        hostError = _s(ev['error']);
        pairLink = _s(ev['link']);
        final left = _i(ev['expiresIn']);
        pairUntil = pairLink.isEmpty ? null : _clock().add(Duration(seconds: left));
        phones = [
          for (final p in (ev['devices'] as List? ?? const []))
            if (p is Map<String, dynamic>) PairedPhone.fromJson(p),
        ];
      case 'remoteDevices':
        scanning = ev['scanning'] == true;
        scanError = _s(ev['error']);
        devices = [
          for (final d in (ev['devices'] as List? ?? const []))
            if (d is Map<String, dynamic>) RemoteDevice.fromJson(d),
        ];
      case 'remoteLink':
        _onLink(ev);
      case 'remoteEvent':
        final inner = ev['event'];
        if (inner is! Map<String, dynamic> || _s(ev['id']) != linkId) return true;
        _onRemote(inner);
      default:
        return false;
    }
    notifyListeners();
    return true;
  }

  void _onLink(Map<String, dynamic> ev) {
    final id = _s(ev['id']);
    final next = LinkStatus.values.asNameMap()[_s(ev['status'])] ?? LinkStatus.idle;
    if (next == LinkStatus.idle) {
      if (id == linkId) {
        status = LinkStatus.idle;
        linkId = '';
        target = false;
      }
      return;
    }
    if (id.isNotEmpty && id != linkId) {
      if (status == LinkStatus.online && next != LinkStatus.pairing) return;
      _reset();
      linkId = id;
    }
    if (_s(ev['name']).isNotEmpty) linkName = _s(ev['name']);
    status = next;
    linkMessage = _s(ev['message']);
    if (next == LinkStatus.failed) target = false;
    if (next != LinkStatus.online) {
      _ticker?.cancel();
      _ticker = null;
    } else {
      _setBase(_now());
    }
  }

  void _onRemote(Map<String, dynamic> ev) {
    switch (ev['type']) {
      case 'player':
        final t = ev['track'];
        final n = ev['next'];
        final previous = track?.id;
        track = t is Map<String, dynamic> ? PlayTrack.fromJson(t) : null;
        next = n is Map<String, dynamic> ? PlayTrack.fromJson(n) : null;
        art = _s(ev['art']);
        pos = _i(ev['pos']);
        count = _i(ev['count']);
        repeat = Repeat.values.asNameMap()[_s(ev['repeat'])] ?? Repeat.off;
        shuffle = ev['shuffle'] == true;
        wave = ev['wave'] == true;
        loading = ev['loading'] == true;
        final s = ev['source'];
        source = s is Map<String, dynamic> ? PlaySource.fromJson(s) : null;
        if (!_holdingVolume) volume = (ev['volume'] as num?)?.toDouble() ?? volume;
        if (track?.id != previous) {
          format = '';
          _setBase(Duration.zero);
        }
        final current = track;
        if (current != null) _marks.remove(current.id);
      case 'queue':
        queue = _tracks(ev['tracks']);
        pos = _i(ev['pos']);
      case 'mark':
        _marks[_s(ev['track'])] = (ev['liked'] == true, ev['disliked'] == true);
      case 'playerFormat':
        if (ev['track'] == track?.id) format = _s(ev['format']);
      case 'playback':
        playing = ev['playing'] == true;
        if (!_holdingVolume) volume = (ev['volume'] as num?)?.toDouble() ?? volume;
        final id = _s(ev['track']);
        if (id.isEmpty || id == track?.id) {
          _setBase(Duration(milliseconds: (((ev['position'] as num?) ?? 0) * 1000).round()));
        } else {
          _setBase(_now());
        }
    }
  }

  bool get _holdingVolume {
    final held = _volumeHeld;
    return held != null && _clock().difference(held) < _volumeHold;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _volumeTimer?.cancel();
    position.dispose();
    super.dispose();
  }
}
