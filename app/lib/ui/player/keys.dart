import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/player.dart';

class PlayerKeys extends StatelessWidget {
  const PlayerKeys({super.key, required this.p, required this.enabled, required this.child});

  final PlayerState p;
  final bool Function() enabled;
  final Widget child;

  static bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  static bool get _nothingFocused {
    final node = FocusManager.instance.primaryFocus;
    return node == null || node is FocusScopeNode;
  }

  bool _handle(KeyEvent e) {
    if (e is! KeyDownEvent || !enabled()) return false;
    final key = e.logicalKey;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      p.togglePlay();
      return true;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      p.nextTrack();
      return true;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      p.previousTrack();
      return true;
    }
    if (_typing || !p.hasTrack) return false;
    if (ctrl && key == LogicalKeyboardKey.arrowRight) {
      p.nextTrack();
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.arrowLeft) {
      p.previousTrack();
      return true;
    }
    if (!ctrl && key == LogicalKeyboardKey.space && _nothingFocused) {
      p.togglePlay();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) => _handle(e) ? KeyEventResult.handled : KeyEventResult.ignored,
      child: child,
    );
  }
}
