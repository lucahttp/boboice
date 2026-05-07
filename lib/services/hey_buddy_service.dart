import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'onnx_pipeline.dart';

/// Wake word detection service that wraps OnnxPipeline with hey-buddy JS-style callbacks.
///
/// Mirrors the JavaScript API from https://github.com/painebenjamin/hey-buddy
///
/// Callbacks:
///   onDetected     — wake word phrase detected (e.g. "hey buddy")
///   onRecording    — speech ended, full audio clip available (Float32List)
///   onProcessed    — every frame: state, VAD prob, wake word probs
///   onSpeechStart  — VAD detected speech start
///   onSpeechEnd    — VAD detected speech end (triggers recording dispatch)
class HeyBuddyService {
  OnnxPipeline? _pipeline;
  bool _recording = false;
  Float32List? _recordingBuffer;

  final _speechProbController = StreamController<double>.broadcast();
  final _wakeWordProbController = StreamController<Map<String, double>>.broadcast();

  /// True when actively capturing audio after wake word fired.
  bool get isRecording => _recording;

  /// Stream of VAD probability (0.0–1.0) for visualization.
  Stream<double> get speechProbabilityStream => _speechProbController.stream;

  /// Stream of per-model wake word probabilities for visualization.
  Stream<Map<String, double>> get wakeWordProbabilityStream => _wakeWordProbController.stream;

  // ── Callbacks (mirror JS API) ─────────────────────────────────────────────

  /// Called with wake word phrase when detected.
  void Function(String wakeWord)? onDetected;

  /// Called when speech ends with the full recorded audio clip (Float32List, 16kHz mono).
  void Function(Float32List audioSamples)? onRecording;

  /// Called every processed frame with state info.
  /// data: { listening, recording, speech: { probability, active }, wakeWords: { name: { probability, active } } }
  void Function(_ProcessedData data)? onProcessed;

  /// Called when voice activity starts.
  void Function()? onSpeechStart;

  /// Called when voice activity ends (triggers recording dispatch).
  void Function()? onSpeechEnd;

  /// Initialize with ONNX model paths.
  Future<void> initialize({
    required String melSpectrogramPath,
    required String speechEmbeddingPath,
    required String wakeWordPath,
    required String vadModelPath,
  }) async {
    _pipeline = OnnxPipeline();

    double _lastSpeechProb = 0.0;
    bool _lastSpeaking = false;
    final Map<String, double> _lastWakeProbs = {};

    _pipeline!.onSpeechProbability = (prob) {
      _speechProbController.add(prob);
      _lastSpeechProb = prob;

      // Track speech start/end
      final isSpeaking = prob > 0.5;
      if (isSpeaking && !_lastSpeaking) {
        _lastSpeaking = true;
        onSpeechStart?.call();
      } else if (!isSpeaking && _lastSpeaking) {
        _lastSpeaking = false;
        onSpeechEnd?.call();
        _dispatchRecordingIfNeeded();
      }
    };

    _pipeline!.onMelSpectrogram = (frames) {
      // Could forward for visualization if needed
    };

    await _pipeline!.initialize(
      melSpectrogramPath: melSpectrogramPath,
      speechEmbeddingPath: speechEmbeddingPath,
      wakeWordPath: wakeWordPath,
      vadModelPath: vadModelPath,
    );
  }

  void start() {
    _pipeline?.start();
  }

  void stop() {
    _dispatchRecordingIfNeeded();
    _pipeline?.stop();
  }

  void _dispatchRecordingIfNeeded() {
    if (!_recording || _recordingBuffer == null) return;
    final audio = _recordingBuffer!;
    _recordingBuffer = null;
    _recording = false;
    onRecording?.call(audio);
  }

  void dispose() {
    stop();
    _pipeline?.dispose();
    _speechProbController.close();
    _wakeWordProbController.close();
  }
}

/// Processed frame data — mirrors JS hey-buddy onProcessed payload.
class _ProcessedData {
  final bool listening;
  final bool recording;
  final double speechProbability;
  final bool speechActive;
  final Map<String, double> wakeWordProbabilities;

  _ProcessedData({
    required this.listening,
    required this.recording,
    required this.speechProbability,
    required this.speechActive,
    required this.wakeWordProbabilities,
  });
}
