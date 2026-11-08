import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/models.dart';
import '../theme.dart';

const phoneWidth = 600.0;

bool isPhone(BuildContext context) => MediaQuery.sizeOf(context).width < phoneWidth;

double sidePad(BuildContext context) => isPhone(context) ? 16 : 28;

Duration motion(BuildContext context, Duration d) =>
    MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : d;

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(gradient: brandGradient, borderRadius: BorderRadius.circular(size * 0.3)),
      child: CustomPaint(painter: const _BrandGlyph(Color(0xFF1A1600))),
    );
  }
}

class _BrandGlyph extends CustomPainter {
  const _BrandGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide * 0.84;
    final o = Offset((size.width - s) / 2, (size.height - s) / 2);
    Offset at(double u, double v) => o + Offset(u * s, v * s);
    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    final tri = Path()
      ..moveTo(at(0.2392, 0.3993).dx, at(0.2392, 0.3993).dy)
      ..lineTo(at(0.2392, 0.6007).dx, at(0.2392, 0.6007).dy)
      ..lineTo(at(0.3966, 0.5).dx, at(0.3966, 0.5).dy)
      ..close();
    canvas.drawPath(tri, fill);
    canvas.drawPath(
      tri,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.12 * s
        ..strokeJoin = StrokeJoin.round,
    );
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.085 * s
      ..strokeCap = StrokeCap.round;
    final c = at(0.485, 0.5);
    for (final (r, span) in const [(0.1575, 42.0), (0.3175, 46.0)]) {
      final a = span * math.pi / 180;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r * s), -a, 2 * a, false, arc);
    }
  }

  @override
  bool shouldRepaint(_BrandGlyph old) => old.color != color;
}

class PlusBadge extends StatelessWidget {
  const PlusBadge({super.key, this.label = 'Плюс'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(gradient: plusGradient, borderRadius: BorderRadius.circular(20)),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.2),
      ),
    );
  }
}

class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, required this.account, this.size = 32});

  final Account account;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: account.hasPlus ? plusGradient : null,
        color: account.hasPlus ? null : scheme.surfaceContainerHighest,
      ),
      child: Text(
        account.initial,
        style: TextStyle(
          color: account.hasPlus ? Colors.white : scheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}

int coverDecodeSize(double logical, double dpr) {
  final px = (logical * dpr).ceil();
  var step = 64;
  while (step < px && step < 2048) {
    step *= 2;
  }
  return step;
}

class Cover extends StatefulWidget {
  const Cover({super.key, required this.url, required this.size, this.kind = ReleaseKind.album, this.radius});

  final String url;
  final double size;
  final ReleaseKind kind;
  final double? radius;

  @override
  State<Cover> createState() => _CoverState();
}

class _CoverState extends State<Cover> {
  var _shown = false;

  IconData get _icon => switch (widget.kind) {
    ReleaseKind.track => Icons.music_note_rounded,
    ReleaseKind.album => Icons.album_rounded,
    ReleaseKind.playlist => Icons.queue_music_rounded,
    ReleaseKind.artist => Icons.person_rounded,
  };

  @override
  void didUpdateWidget(Cover old) {
    super.didUpdateWidget(old);
    if (widget.url.isEmpty) _shown = false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    final r = widget.radius ?? size * 0.14;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.surfaceContainerHighest, scheme.surfaceContainerHigh],
        ),
      ),
      child: Icon(_icon, size: size * 0.42, color: scheme.onSurfaceVariant),
    );
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.kind == ReleaseKind.artist ? size : r),
      child: SizedBox(
        width: size,
        height: size,
        child: widget.url.isEmpty
            ? placeholder
            : Image.network(
                widget.url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                cacheWidth: coverDecodeSize(size, dpr),
                errorBuilder: (_, _, _) => placeholder,
                frameBuilder: (context, child, frame, sync) {
                  if (frame != null) _shown = true;
                  if (sync || _shown) return child;
                  return AnimatedSwitcher(
                    duration: motion(context, const Duration(milliseconds: 250)),
                    child: frame == null ? placeholder : child,
                  );
                },
              ),
      ),
    );
  }
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: child,
    );
  }
}

class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (color ?? scheme.onSurfaceVariant).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 4)],
          Text(
            label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
  }
}

class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key, this.size = 15});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Содержит ненормативную лексику (18+)',
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(size * 0.22),
        ),
        child: Text(
          'E',
          style: TextStyle(fontSize: size * 0.68, height: 1, fontWeight: FontWeight.w800, color: scheme.surface),
        ),
      ),
    );
  }
}

class TitleWithBadge extends StatelessWidget {
  const TitleWithBadge(this.title, {super.key, required this.explicit, this.style});

  final String title;
  final bool explicit;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Tooltip(
            message: title,
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
        ),
        if (explicit) ...[const SizedBox(width: 6), const ExplicitBadge()],
      ],
    );
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45)),
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
