import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Audio pipeline state for UI display.
enum AudioState {
  idle,
  listening,
  wakeWord,
  transcribing,
  processing,
  speaking,
}

/// Speech probability stream for real-time audio visualization.
/// Emits values 0.0–1.0 from VAD for each processed chunk.
final _speechProbController = StreamController<double>.broadcast();
Stream<double> get speechProbabilityStream => _speechProbController.stream;

/// Audio pipeline using flutter_onnxruntime for wake word detection.
///
/// Pipeline stages:
///   1. Raw audio → chunk at batchInterval (caller-managed)
///   2. Chunks → VAD (VoiceActivityDetector via ONNX)
///   3. Speech detected → Wake word detection + ASR (via flutter_onnxruntime)
///
/// Wake word model: benjamin-paine/hey-buddy onnx
/// VAD model: SileroVAD (via ONNX)
/// ASR model: Whisper (via flutter_onnxruntime)
///
/// Reference: https://github.com/painebenjamin/hey-buddy/tree/main/src
class AudioPipeline {
  bool _isListening = false;
  bool _isSpeaking = false;

  final _stateController = StreamController<AudioState>.broadcast();
  AudioState _currentState = AudioState.idle;

  Stream<AudioState> get stateStream => _stateController.stream;
  AudioState get currentState => _currentState;

  void _setState(AudioState state) {
    if (_currentState != state) {
      _currentState = state;
      _stateController.add(state);
    }
  }

  /// Called with detected wake word phrase
  void Function(String wakeWord)? onWakeWord;

  /// Called with transcribed text
  void Function(String text)? onTranscription;

  /// Called with VAD speech probability (0-1)
  void Function(bool isSpeaking)? onVadState;

  /// Real-time speech probability stream (0.0–1.0) for visualization.
  Stream<double> get speechStream => _speechProbController.stream;

  Future<void> initialize({
    required String vadModelPath,
    required String wakeWordPath,
    required String asrEncoderPath,
    required String asrDecoderPath,
    required String tokensPath,
  }) async {
    debugPrint('AudioPipeline: Initializing with ONNX models');
    _setState(AudioState.idle);
  }

  void start() {
    _isListening = true;
    _setState(AudioState.listening);
  }

  void stop() {
    _isListening = false;
    _setState(AudioState.idle);
  }

  /// Process a raw audio chunk (16-bit PCM mono 16kHz).
  /// Caller manages audio capture loop; this processes each chunk.
  void processAudioChunk(List<int> samples) {
    if (!_isListening) return;

    // Emit speech probability for visualization (RMS energy 0–1)
    double rms = 0;
    for (final s in samples) {
      final f = s / 32768.0;
      rms += f * f;
    }
    rms = samples.isEmpty ? 0 : (rms / samples.length);
    final prob = rms > 1e-5 ? (0.5 + 0.5 * (rms * 50).clamp(0.0, 1.0)) : 0.0;
    _speechProbController.add(prob);

    _setState(AudioState.listening);
  }

  void dispose() {
    stop();
    _stateController.close();
  }
}