import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Real-time scrolling spectrogram visualization for voice activity.
/// Shows 32-bin mel spectrogram data as a color-coded heatmap
/// that scrolls from right to left (most recent on the right).
class MelSpectrogramVisualizer extends StatefulWidget {
  /// Stream of mel spectrogram frames [numFrames, 32] flat
  final Stream<Float32List>? melStream;
  final double height;
  final double width;

  const MelSpectrogramVisualizer({
    super.key,
    this.melStream,
    this.height = 60,
    this.width = double.infinity,
  });

  @override
  State<MelSpectrogramVisualizer> createState() => _MelSpectrogramVisualizerState();
}

class _MelSpectrogramVisualizerState extends State<MelSpectrogramVisualizer> {
  final List<Float32List> _frameHistory = [];
  static const int _maxFrames = 100; // 100 frames = ~2.6 seconds of history
  StreamSubscription<Float32List>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.melStream?.listen(_onMelFrames);
  }

  void _onMelFrames(Float32List frames) {
    if (!mounted) return;
    final numFrames = frames.length ~/ 32;
    if (numFrames == 0) return;

    // Reshape to [numFrames, 32]
    final frameData = Float32List(numFrames * 32);
    for (int i = 0; i < numFrames * 32 && i < frames.length; i++) {
      frameData[i] = frames[i];
    }

    setState(() {
      _frameHistory.add(frameData);
      while (_frameHistory.length > _maxFrames) {
        _frameHistory.removeAt(0);
      }
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
      width: widget.width,
      child: CustomPaint(
        painter: _SpectrogramPainter(history: _frameHistory),
        size: Size.infinite,
      ),
    );
  }
}

class _SpectrogramPainter extends CustomPainter {
  final List<Float32List> history;

  _SpectrogramPainter({required this.history});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }

    final binCount = 32;
    final pixelsPerFrame = size.width / 100;
    final barHeight = size.height / binCount;

    for (int frameIdx = 0; frameIdx < history.length; frameIdx++) {
      final x = (history.length - 1 - frameIdx) * pixelsPerFrame;
      if (x < 0) continue;

      final frame = history[frameIdx];
      for (int bin = 0; bin < binCount && bin * binCount < frame.length; bin++) {
        final value = frame[bin * binCount];
        // value is already processed: datum / 10 + 2, range approx 0-4
        // Normalize to 0-1 for color mapping
        final normalized = (value / 4.0).clamp(0.0, 1.0);
        final color = _heatmapColor(normalized);
        
        final paint = Paint()..color = color;
        canvas.drawRect(
          Rect.fromLTWH(x, size.height - (bin + 1) * barHeight, pixelsPerFrame, barHeight),
          paint,
        );
      }
    }
  }

  void _paintEmpty(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.grey.shade900;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  Color _heatmapColor(double value) {
    // Blue (low) -> Cyan -> Green -> Yellow -> Red (high)
    if (value < 0.25) {
      return Color.lerp(Colors.blue.shade900, Colors.blue, value * 4)!;
    } else if (value < 0.5) {
      return Color.lerp(Colors.blue, Colors.cyan, (value - 0.25) * 4)!;
    } else if (value < 0.75) {
      return Color.lerp(Colors.cyan, Colors.green, (value - 0.5) * 4)!;
    } else {
      return Color.lerp(Colors.green, Colors.red, (value - 0.75) * 4)!;
    }
  }

  @override
  bool shouldRepaint(_SpectrogramPainter old) => history.length != old.history.length;
}