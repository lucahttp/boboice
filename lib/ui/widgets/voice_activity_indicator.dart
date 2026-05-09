import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/audio_pipeline.dart' show AudioState;

/// Animated circular indicator for Buddy's audio state.
///
/// Visual design (inspired by Google Assistant/Alexa):
///   idle        — gray ring, static
///   listening   — blue ring, slow breathing pulse
///   wakeWord    — green ring, fast flash then ripple
///   processing  — orange ring, spinning arc
///   speaking    — purple ring, animated waveform bars
class VoiceActivityIndicator extends StatefulWidget {
  final AudioState state;
  final double size;

  const VoiceActivityIndicator({
    super.key,
    required this.state,
    this.size = 72,
  });

  @override
  State<VoiceActivityIndicator> createState() => _VoiceActivityIndicatorState();
}

class _VoiceActivityIndicatorState extends State<VoiceActivityIndicator>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _spinController;
  late AnimationController _rippleController;
  late Animation<double> _pulseAnim;
  late Animation<double> _rippleAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _spinController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _rippleController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _rippleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _rippleController, curve: Curves.easeOut),
    );
    _pulseController.repeat(reverse: true);
    _spinController.repeat();
  }

  @override
  void didUpdateWidget(VoiceActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _onStateChanged();
    }
  }

  void _onStateChanged() {
    _pulseController.stop();
    _rippleController.stop();
    _spinController.stop();
    switch (widget.state) {
      case AudioState.idle:
        break;
      case AudioState.listening:
        _pulseController.repeat(reverse: true);
      case AudioState.wakeWord:
        _rippleController.forward().then((_) => _rippleController.reverse());
        _pulseController.repeat(reverse: true);
      case AudioState.transcribing:
        _spinController.repeat();
      case AudioState.processing:
        _spinController.repeat();
      case AudioState.speaking:
        break;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _spinController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseAnim, _rippleAnim]),
        builder: (context, child) {
          return CustomPaint(
            painter: _VoiceIndicatorPainter(
              state: widget.state,
              pulse: _pulseAnim.value,
              ripple: _rippleAnim.value,
              spin: _spinController.value,
            ),
            size: Size(widget.size, widget.size),
          );
        },
      ),
    );
  }
}

class _VoiceIndicatorPainter extends CustomPainter {
  final AudioState state;
  final double pulse;
  final double ripple;
  final double spin;

  _VoiceIndicatorPainter({
    required this.state,
    required this.pulse,
    required this.ripple,
    required this.spin,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width / 2 - 6;

    final color = switch (state) {
      AudioState.idle => const Color(0xFF9E9E9E),
      AudioState.listening => const Color(0xFF2196F3),
      AudioState.wakeWord => const Color(0xFF4CAF50),
      AudioState.transcribing => const Color(0xFFFF5722),
      AudioState.processing => const Color(0xFFFF9800),
      AudioState.speaking => const Color(0xFF9C27B0),
    };

    // Ripple rings for wake word
    if (state == AudioState.wakeWord && ripple > 0) {
      for (int i = 0; i < 2; i++) {
        final r = baseRadius * (1 + ripple * (0.4 + i * 0.2));
        final paint = Paint()
          ..color = color.withAlpha(((1 - ripple) * 80).toInt())
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        canvas.drawCircle(center, r, paint);
      }
    }

    // Main ring
    final ringRadius = state == AudioState.listening ? baseRadius * pulse : baseRadius;
    final ringPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, ringRadius, ringPaint);

    // Spinning arc for processing
    if (state == AudioState.processing) {
      final arcPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      const sweepAngle = math.pi * 0.7;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringRadius - 6),
        spin * math.pi * 2,
        sweepAngle,
        false,
        arcPaint,
      );
    }

    // Center icon
    final iconPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    if (state == AudioState.listening) {
      // Mic icon (simplified)
      _drawMic(canvas, center, ringRadius * 0.45, iconPaint);
    } else if (state == AudioState.wakeWord) {
      // Checkmark
      _drawCheck(canvas, center, ringRadius * 0.45, iconPaint);
    } else if (state == AudioState.processing) {
      // Spinning dots
      _drawDots(canvas, center, ringRadius * 0.35, color);
    } else if (state == AudioState.speaking) {
      // Waveform bars
      _drawWaveform(canvas, center, ringRadius * 0.5, color);
    } else if (state == AudioState.idle) {
      // Mic outline
      _drawMic(canvas, center, ringRadius * 0.45, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  void _drawMic(Canvas canvas, Offset center, double size, Paint paint) {
    final path = Path();
    // Simple mic body
    path.addRRect(RRect.fromRectAndRadius(
      Rect.fromCenter(center: center.translate(0, -size * 0.2), width: size * 0.7, height: size),
      Radius.circular(size * 0.35),
    ));
    // Mic stand arc
    final standPath = Path();
    standPath.addArc(
      Rect.fromCenter(center: center.translate(0, size * 0.5), width: size * 1.2, height: size * 0.8),
      0,
      math.pi,
    );
    canvas.drawPath(path, paint);
    canvas.drawPath(standPath, paint..style = PaintingStyle.stroke..strokeWidth = 2);
  }

  void _drawCheck(Canvas canvas, Offset center, double size, Paint paint) {
    final path = Path();
    path.moveTo(center.dx - size * 0.4, center.dy);
    path.lineTo(center.dx - size * 0.1, center.dy + size * 0.35);
    path.lineTo(center.dx + size * 0.45, center.dy - size * 0.3);
    canvas.drawPath(path, paint..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round);
  }

  void _drawDots(Canvas canvas, Offset center, double radius, Color color) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    for (int i = 0; i < 3; i++) {
      final angle = spin * math.pi * 2 + (i * math.pi * 2 / 3);
      final dot = Offset(center.dx + radius * math.cos(angle), center.dy + radius * math.sin(angle));
      canvas.drawCircle(dot, 3, paint);
    }
  }

  void _drawWaveform(Canvas canvas, Offset center, double width, Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final heights = [0.3, 0.8, 0.5, 1.0, 0.4, 0.9, 0.35];
    final step = width / (heights.length - 1);
    for (int i = 0; i < heights.length - 1; i++) {
      canvas.drawLine(
        Offset(center.dx - width / 2 + i * step, center.dy - heights[i] * width * 0.4),
        Offset(center.dx - width / 2 + (i + 1) * step, center.dy - heights[i + 1] * width * 0.4),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceIndicatorPainter old) {
    return old.state != state ||
        old.pulse != pulse ||
        old.ripple != ripple ||
        old.spin != spin;
  }
}

/// State label shown below the indicator.
class VoiceStateLabel extends StatelessWidget {
  final AudioState state;

  const VoiceStateLabel({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final text = switch (state) {
      AudioState.idle => 'Ready',
      AudioState.listening => 'Listening...',
      AudioState.wakeWord => 'Wake word!',
      AudioState.transcribing => 'Transcribing...',
      AudioState.processing => 'Processing...',
      AudioState.speaking => 'Speaking...',
    };
    final color = switch (state) {
      AudioState.idle => Colors.grey,
      AudioState.listening => const Color(0xFF2196F3),
      AudioState.wakeWord => const Color(0xFF4CAF50),
      AudioState.transcribing => const Color(0xFFFF5722),
      AudioState.processing => const Color(0xFFFF9800),
      AudioState.speaking => const Color(0xFF9C27B0),
    };
    return Text(text, style: TextStyle(color: color, fontSize: 12));
  }
}
