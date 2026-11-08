import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yamp/ui/player/tint.dart';

void main() {
  test('ambient art keeps a flat cover flat and dims it', () {
    final src = Uint8List(112 * 112 * 4);
    for (var i = 0; i < src.length; i += 4) {
      src[i] = 200;
      src[i + 1] = 200;
      src[i + 2] = 200;
      src[i + 3] = 255;
    }
    final out = ambientPixels(src, 112, 112);
    expect(out.length, ambientSide * ambientSide * 4);
    final first = out.sublist(0, 4);
    expect(first[0], closeTo(60, 1));
    expect(first[3], 255);
    for (var i = 0; i < out.length; i += 4) {
      expect(out.sublist(i, i + 4), first);
    }
  });

  test('ambient art softens a hard edge', () {
    final src = Uint8List(112 * 112 * 4);
    for (var y = 0; y < 112; y++) {
      for (var x = 0; x < 112; x++) {
        final i = (y * 112 + x) * 4;
        final v = x < 56 ? 0 : 255;
        src[i] = v;
        src[i + 1] = v;
        src[i + 2] = v;
        src[i + 3] = 255;
      }
    }
    final out = ambientPixels(src, 112, 112);
    final row = 48 * ambientSide * 4;
    final mid = out[row + (ambientSide ~/ 2) * 4];
    expect(mid, greaterThan(10));
    expect(mid, lessThan(66));
    expect(out[row], lessThan(mid));
    expect(out[row + (ambientSide - 1) * 4], greaterThan(mid));
  });
}
