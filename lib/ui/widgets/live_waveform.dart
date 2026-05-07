import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Real-time scrolling waveform showing audio input levels.
/// Inspired by hey-buddy's canvas-based audio visualization.
/// Shows a scrolling line graph of speech probability (0.0–1.0).
class LiveWaveform extends StatefulWidget {
  final Stream<double> probabilityStream;
  final double height;
  final Color color;

  const LiveWaveform({
    super.key,
    required this.probabilityStream,
    this.height = 32,
    this.color = const Color(0xFF2196F3),
  });

  @override
  State<LiveWaveform> createState() => _LiveWaveformState();
}

class _LiveWaveformState extends State<LiveWaveform> {
  final List<double> _history = [];
  static const int _maxPoints = 80;
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.probabilityStream.listen((prob) {
      if (!mounted) return;
      setState(() {
        _history.add(prob.clamp(0.0, 1.0));
        if (_history.length > _maxPoints) {
          _history.removeAt(0);
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: CustomPaint(
        painter: _WaveformPainter(
          history: _history,
          color: widget.color,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> history;
  final Color color;

  _WaveformPainter({required this.history, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = color.withAlpha(60)
      ..style = PaintingStyle.fill;

    final path = Path();
    final fillPath = Path();

    final stepX = size.width / (history.length - 1).clamp(1, double.infinity);

    // Start path
    path.moveTo(0, size.height - history[0] * size.height);
    fillPath.moveTo(0, size.height);
    fillPath.lineTo(0, size.height - history[0] * size.height);

    for (int i = 1; i < history.length; i++) {
      final x = i * stepX;
      final y = size.height - history[i] * size.height;
      path.lineTo(x, y);
      fillPath.lineTo(x, y);
    }

    // Close fill polygon
    fillPath.lineTo((history.length - 1) * stepX, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);

    // Draw center line (silence level)
    final centerPaint = Paint()
      ..color = color.withAlpha(30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), centerPaint);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.history != history;
}