import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/player.dart';

class SystemMedia {
  SystemMedia(this.player, {MethodChannel channel = const MethodChannel('yamp/media'), DateTime Function()? clock})
    : _channel = channel,
      _clock = clock ?? DateTime.now {
    _channel.setMethodCallHandler(_command);
    player.addListener(_sync);
    player.duration.addListener(_sync);
    player.position.addListener(_onPosition);
  }

  final PlayerState player;
  final MethodChannel _channel;
  final DateTime Function() _clock;

  Map<String, Object?>? _sent;
  var _sentPosition = Duration.zero;
  var _sentAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const _drift = Duration(milliseconds: 1500);

  Future<void> _command(MethodCall call) async {
    switch (call.method) {
      case 'play':
        player.resume();
      case 'pause' || 'stop':
        player.pause();
      case 'next':
        player.nextTrack();
      case 'previous':
        player.previousTrack();
      case 'like':
        final t = player.track;
        if (t != null) player.like(t, !player.liked(t));
      case 'dislike':
        final t = player.track;
        if (t != null) player.dislike(t, !player.disliked(t));
      case 'seek':
        final ms = call.arguments;
        if (ms is num) player.seek(Duration(milliseconds: ms.toInt()));
    }
  }

  Map<String, Object?>? _state() {
    final t = player.track;
    if (t == null) return null;
    final duration = player.duration.value > Duration.zero ? player.duration.value : t.duration;
    return {
      'id': t.id,
      'title': t.title,
      'artist': t.artist,
      'album': t.album,
      'art': player.art,
      'duration': duration.inMilliseconds,
      'playing': player.playing,
      'buffering': player.buffering || player.loading,
      'liked': player.liked(t),
      'disliked': player.disliked(t),
    };
  }

  void _sync() {
    final state = _state();
    if (state == null) {
      if (_sent == null) return;
      _sent = null;
      _invoke('stop');
      return;
    }
    if (_sent != null && mapEquals(_sent, state)) return;
    _send(state);
  }

  void _onPosition() {
    final sent = _sent;
    if (sent == null) return;
    var expected = _sentPosition;
    if (sent['playing'] == true && sent['buffering'] != true) expected += _clock().difference(_sentAt);
    if ((player.position.value - expected).abs() > _drift) _send(sent);
  }

  void _send(Map<String, Object?> state) {
    _sent = state;
    _sentPosition = player.position.value;
    _sentAt = _clock();
    _invoke('update', {...state, 'position': _sentPosition.inMilliseconds});
  }

  void _invoke(String method, [Object? args]) {
    unawaited(
      _channel.invokeMethod<void>(method, args).catchError((Object _) {}, test: (e) => e is MissingPluginException),
    );
  }

  void dispose() {
    player.removeListener(_sync);
    player.duration.removeListener(_sync);
    player.position.removeListener(_onPosition);
    _channel.setMethodCallHandler(null);
  }
}
