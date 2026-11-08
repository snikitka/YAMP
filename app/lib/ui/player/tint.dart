import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../widgets.dart';

const _ground = Color(0xFF0E0E12);
const _plain = Color(0xFF17171D);

final _dark = buildTheme(Brightness.dark);

final ThemeData playerTheme = () {
  final s = _dark.colorScheme;
  final white = Colors.white;
  return _dark.copyWith(
    colorScheme: s.copyWith(
      primary: white,
      onPrimary: _ground,
      primaryContainer: white.withValues(alpha: 0.14),
      surfaceContainerHigh: white.withValues(alpha: 0.10),
      surfaceContainerHighest: white.withValues(alpha: 0.16),
      surfaceContainerLow: Colors.black.withValues(alpha: 0.28),
      onSurfaceVariant: white.withValues(alpha: 0.72),
      outlineVariant: white.withValues(alpha: 0.10),
    ),
    sliderTheme: _dark.sliderTheme.copyWith(
      activeTrackColor: white,
      thumbColor: white,
      inactiveTrackColor: white.withValues(alpha: 0.22),
    ),
  );
}();

class CoverTint {
  static final _cache = <String, Color>{};
  static final _pending = <String, Future<Color?>>{};

  static Color? cached(String url) => _cache[url];

  static Future<Color?> resolve(String url) {
    if (url.isEmpty) return Future.value(null);
    final hit = _cache[url];
    if (hit != null) return Future.value(hit);
    return _pending[url] ??= ColorScheme.fromImageProvider(
      provider: _small(url),
      brightness: Brightness.dark,
    ).then<Color?>((s) {
      if (_cache.length > 64) _cache.clear();
      final c = Color.lerp(_ground, s.primaryContainer, 0.66)!;
      _cache[url] = c;
      return c;
    }).catchError((Object _) => null).whenComplete(() {
      _pending.remove(url);
    });
  }
}

const _dim = 0.3;
const _vivid = 1.5;

List<double> _ambientMatrix() {
  final r = (1 - _vivid) * 0.2126, g = (1 - _vivid) * 0.7152, b = (1 - _vivid) * 0.0722;
  return [
    (r + _vivid) * _dim, g * _dim, b * _dim, 0, 0,
    r * _dim, (g + _vivid) * _dim, b * _dim, 0, 0,
    r * _dim, g * _dim, (b + _vivid) * _dim, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

final _matrix = _ambientMatrix();

ImageProvider _small(String url) => ResizeImage(NetworkImage(url), width: 112, height: 112);

const ambientSide = 96;
const _artRadius = 5;
const _artGrow = 0.15;

Uint8List ambientPixels(Uint8List rgba, int width, int height) {
  const n = ambientSide;
  final m = _matrix;
  final inset = _artGrow / (1 + _artGrow * 2);
  final span = 1 - inset * 2;
  final buf = Float32List(n * n * 3);
  for (var y = 0; y < n; y++) {
    final sy = ((inset + (y + 0.5) / n * span) * height).floor().clamp(0, height - 1);
    for (var x = 0; x < n; x++) {
      final sx = ((inset + (x + 0.5) / n * span) * width).floor().clamp(0, width - 1);
      final i = (sy * width + sx) * 4;
      final r = rgba[i].toDouble(), g = rgba[i + 1].toDouble(), b = rgba[i + 2].toDouble();
      final o = (y * n + x) * 3;
      buf[o] = m[0] * r + m[1] * g + m[2] * b;
      buf[o + 1] = m[5] * r + m[6] * g + m[7] * b;
      buf[o + 2] = m[10] * r + m[11] * g + m[12] * b;
    }
  }
  final tmp = Float32List(buf.length);
  for (var pass = 0; pass < 3; pass++) {
    _boxBlur(buf, tmp, n, 3, n * 3);
    _boxBlur(tmp, buf, n, n * 3, 3);
  }
  final out = Uint8List(n * n * 4);
  for (var i = 0, o = 0; i < buf.length; i += 3, o += 4) {
    out[o] = buf[i].round().clamp(0, 255);
    out[o + 1] = buf[i + 1].round().clamp(0, 255);
    out[o + 2] = buf[i + 2].round().clamp(0, 255);
    out[o + 3] = 255;
  }
  return out;
}

void _boxBlur(Float32List src, Float32List dst, int n, int step, int line) {
  const r = _artRadius;
  const width = r * 2 + 1;
  for (var l = 0; l < n; l++) {
    for (var c = 0; c < 3; c++) {
      final base = l * line + c;
      double at(int k) => src[base + k.clamp(0, n - 1) * step];
      var sum = 0.0;
      for (var k = -r; k <= r; k++) {
        sum += at(k);
      }
      for (var k = 0; k < n; k++) {
        dst[base + k * step] = sum / width;
        sum += at(k + r + 1) - at(k - r);
      }
    }
  }
}

class AmbientArt {
  static final _cache = <String, ui.Image>{};
  static final _pending = <String, Future<ui.Image?>>{};

  static ui.Image? cached(String url) => _cache[url]?.clone();

  static Future<ui.Image?> resolve(String url) async {
    if (url.isEmpty) return null;
    final hit = _cache[url];
    if (hit != null) return hit.clone();
    final art = await (_pending[url] ??= _render(url).whenComplete(() {
      _pending.remove(url);
    }));
    return art?.clone();
  }

  static Future<ui.Image?> _render(String url) async {
    final ByteData? data;
    final int width, height;
    try {
      final info = await _decode(_small(url));
      width = info.image.width;
      height = info.image.height;
      try {
        data = await info.image.toByteData();
      } finally {
        info.dispose();
      }
    } catch (_) {
      return null;
    }
    if (data == null) return null;
    final pixels = ambientPixels(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), width, height);
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, ambientSide, ambientSide, ui.PixelFormat.rgba8888, done.complete);
    final art = await done.future;
    if (_cache.length >= 8) _cache.remove(_cache.keys.first)?.dispose();
    _cache[url] = art;
    return art;
  }

  static Future<ImageInfo> _decode(ImageProvider provider) {
    final done = Completer<ImageInfo>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!done.isCompleted) done.complete(info);
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        if (!done.isCompleted) done.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return done.future;
  }
}

class _Ambient extends StatefulWidget {
  const _Ambient({required this.url});

  final String url;

  @override
  State<_Ambient> createState() => _AmbientState();
}

class _AmbientState extends State<_Ambient> {
  late ui.Image? _art = AmbientArt.cached(widget.url);

  @override
  void initState() {
    super.initState();
    if (_art != null) return;
    AmbientArt.resolve(widget.url).then((art) {
      if (!mounted) {
        art?.dispose();
        return;
      }
      setState(() => _art = art);
    });
  }

  @override
  void dispose() {
    _art?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _art == null ? 0 : 1,
      duration: motion(context, const Duration(milliseconds: 400)),
      child: RawImage(image: _art, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
    );
  }
}

class PlayerBackdrop extends StatefulWidget {
  const PlayerBackdrop({super.key, required this.url, required this.child});

  final String url;
  final Widget child;

  @override
  State<PlayerBackdrop> createState() => _PlayerBackdropState();
}

class _PlayerBackdropState extends State<PlayerBackdrop> {
  late Color _color = CoverTint.cached(widget.url) ?? _plain;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(PlayerBackdrop old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _resolve();
  }

  void _resolve() {
    final url = widget.url;
    if (url.isEmpty) {
      _color = _plain;
      return;
    }
    CoverTint.resolve(url).then((c) {
      if (!mounted || widget.url != url) return;
      setState(() => _color = c ?? _plain);
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    final fade = motion(context, const Duration(milliseconds: 700));
    return AnimatedContainer(
      duration: fade,
      curve: Curves.easeOut,
      color: _color,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: AnimatedSwitcher(
              duration: fade,
              child: url.isEmpty
                  ? const SizedBox.expand()
                  : SizedBox.expand(key: ValueKey(url), child: _Ambient(url: url)),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x1A000000), Color(0x33000000), Color(0x80000000)],
                stops: [0, 0.5, 1],
              ),
            ),
          ),
          Material(type: MaterialType.transparency, child: widget.child),
        ],
      ),
    );
  }
}
