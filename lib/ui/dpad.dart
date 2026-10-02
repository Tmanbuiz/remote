import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/remote_controller.dart';
import '../core/remote_key.dart';
import 'key_press.dart';
import 'theme.dart';

/// The directional pad, as one object rather than five separate buttons.
///
/// A real remote's pad is a single ring with a key in the middle, and the
/// thumb finds it by feel. Five identical circles in a cross lose that: there
/// is nothing to aim at and nothing that reads as the centre. This draws the
/// ring as one surface, puts the only bright thing in the app at its middle,
/// and lights the quadrant under the thumb.
class DPad extends StatefulWidget {
  const DPad({super.key, this.diameter = 260});

  final double diameter;

  @override
  State<DPad> createState() => _DPadState();
}

class _DPadState extends State<DPad> {
  RemoteKey? _lit;

  /// Which quadrant a point falls in, or null for the centre key.
  RemoteKey? _hit(Offset local) {
    final radius = widget.diameter / 2;
    final from = local - Offset(radius, radius);
    if (from.distance < radius * 0.31) return RemoteKey.select;
    if (from.distance > radius) return null;
    // Screen y grows downward, so negate it to get a conventional angle.
    final angle = math.atan2(-from.dy, from.dx);
    const quarter = math.pi / 4;
    if (angle >= quarter && angle < 3 * quarter) return RemoteKey.up;
    if (angle >= -quarter && angle < quarter) return RemoteKey.right;
    if (angle >= -3 * quarter && angle < -quarter) return RemoteKey.down;
    return RemoteKey.left;
  }

  Future<void> _fire(RemoteKey key) async {
    final controller = context.read<RemoteController>();
    if (!controller.supportedKeys.contains(key)) return;
    await pressKey(context, key);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RemoteController>();
    final radius = widget.diameter / 2;

    return SizedBox(
      width: widget.diameter,
      height: widget.diameter,
      child: Listener(
        onPointerDown: (event) {
          final key = _hit(event.localPosition);
          if (key == null) return;
          setState(() => _lit = key);
          _fire(key);
        },
        onPointerUp: (_) => setState(() => _lit = null),
        onPointerCancel: (_) => setState(() => _lit = null),
        child: CustomPaint(
          painter: _DPadPainter(
            lit: _lit,
            enabled: controller.supportedKeys,
          ),
          child: Center(
            child: AnimatedScale(
              scale: _lit == RemoteKey.select ? 0.92 : 1,
              duration: RemoteTheme.press,
              child: Container(
                width: radius * 0.62,
                height: radius * 0.62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF6FE3D8), RemoteTheme.accentDim],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: RemoteTheme.accent.withValues(alpha: 0.35),
                      blurRadius: 24,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Center(
                  child: Text(
                    'OK',
                    style: TextStyle(
                      color: Color(0xFF04211F),
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DPadPainter extends CustomPainter {
  _DPadPainter({required this.lit, required this.enabled});

  final RemoteKey? lit;
  final Set<RemoteKey> enabled;

  static const _quadrants = <RemoteKey, double>{
    RemoteKey.up: -math.pi * 0.75,
    RemoteKey.right: -math.pi * 0.25,
    RemoteKey.down: math.pi * 0.25,
    RemoteKey.left: math.pi * 0.75,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width / 2;
    final ring = Rect.fromCircle(center: centre, radius: radius);

    // The pad itself, lit from the top-left so it reads as a raised surface
    // rather than a flat disc.
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF17262A), Color(0xFF0C1518)],
        ).createShader(ring),
    );

    // The quadrant under the thumb.
    final litAngle = lit == null ? null : _quadrants[lit];
    if (litAngle != null) {
      canvas.drawArc(
        ring.deflate(2),
        litAngle,
        math.pi / 2,
        true,
        Paint()..color = RemoteTheme.accent.withValues(alpha: 0.16),
      );
    }

    // A hairline rather than a heavy border: enough to separate the pad from
    // the backdrop without drawing attention to itself.
    canvas.drawCircle(
      centre,
      radius - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = RemoteTheme.hairline,
    );

    // Chevrons, dimmed when the TV does not implement that direction.
    const directions = {
      RemoteKey.up: -math.pi / 2,
      RemoteKey.right: 0.0,
      RemoteKey.down: math.pi / 2,
      RemoteKey.left: math.pi,
    };
    directions.forEach((key, angle) {
      final on = enabled.contains(key);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = lit == key
            ? RemoteTheme.accent
            : (on ? RemoteTheme.text.withValues(alpha: 0.72) : RemoteTheme.textMuted.withValues(alpha: 0.28));

      final distance = radius * 0.72;
      final tip = centre + Offset(math.cos(angle), math.sin(angle)) * distance;
      const arm = 7.0;
      final back = angle + math.pi;
      final a = tip + Offset(math.cos(back + 0.6), math.sin(back + 0.6)) * arm;
      final b = tip + Offset(math.cos(back - 0.6), math.sin(back - 0.6)) * arm;
      canvas.drawPath(Path()..moveTo(a.dx, a.dy)..lineTo(tip.dx, tip.dy)..lineTo(b.dx, b.dy), paint);
    });
  }

  @override
  bool shouldRepaint(_DPadPainter old) => old.lit != lit || old.enabled != enabled;
}
