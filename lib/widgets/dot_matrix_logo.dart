import 'dart:math' as math;
import 'package:flutter/material.dart';

class DotMatrixLogo extends StatelessWidget {
  final double size;
  final Color? color;
  final double paddingRatio;

  const DotMatrixLogo({
    super.key,
    this.size = 28,
    this.color,
    this.paddingRatio = 0.08,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = color ?? Theme.of(context).colorScheme.onSurface;
    return CustomPaint(
      size: Size(size, size),
      painter: _DotMatrixPainter(
        color: dotColor,
        paddingRatio: paddingRatio,
      ),
    );
  }
}

class _DotMatrixPainter extends CustomPainter {
  final Color color;
  final double paddingRatio;

  _DotMatrixPainter({
    required this.color,
    required this.paddingRatio,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;

    final cx = size.width / 2.0;
    final cy = size.height / 2.0;

    final side = math.min(size.width, size.height);
    final contentSize = side * (1.0 - 2.0 * paddingRatio);
    final delta = contentSize / 4.75;

    final r1 = delta * 0.355; // 4 center dots
    final r2 = delta * 0.235; // 12 middle dots
    final r3 = delta * 0.130; // 8 outer tip dots
    const tipOff = 2.26;

    // 4 center dots
    for (final dy in const [-0.5, 0.5]) {
      for (final dx in const [-0.5, 0.5]) {
        canvas.drawCircle(Offset(cx + dx * delta, cy + dy * delta), r1, paint);
      }
    }

    // 12 middle dots
    for (final dy in const [-1.5, 1.5]) {
      for (final dx in const [-1.5, -0.5, 0.5, 1.5]) {
        canvas.drawCircle(Offset(cx + dx * delta, cy + dy * delta), r2, paint);
      }
    }
    for (final dy in const [-0.5, 0.5]) {
      for (final dx in const [-1.5, 1.5]) {
        canvas.drawCircle(Offset(cx + dx * delta, cy + dy * delta), r2, paint);
      }
    }

    // 8 outer tips
    for (final dy in const [-0.5, 0.5]) {
      for (final dx in const [-tipOff, tipOff]) {
        canvas.drawCircle(Offset(cx + dx * delta, cy + dy * delta), r3, paint);
      }
    }
    for (final dy in const [-tipOff, tipOff]) {
      for (final dx in const [-0.5, 0.5]) {
        canvas.drawCircle(Offset(cx + dx * delta, cy + dy * delta), r3, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotMatrixPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.paddingRatio != paddingRatio;
  }
}
