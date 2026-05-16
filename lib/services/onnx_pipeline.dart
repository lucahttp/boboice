import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'audio_pipeline.dart';

/// ONNX-based audio pipeline that mirrors hey-buddy's JavaScript implementation.
/// Uses flutter_onnxruntime to run ONNX models natively.
///
/// Reference: https://github.com/painebenjamin/hey-buddy/blob/main/src/js/src/hey-buddy.js
///
/// Key parameters from JS reference:
/// - Mel spectrogram: input[N] → output[time, 76, 32], postprocess: datum/10 + 2
/// - Speech embedding: windowSize=76, windowStride=8, input [time, 32] → output [numBatches, 96]
/// - Wake word: 16 embeddings of 96-dim → [1, 16, 96], threshold=0.5
class OnnxPipeline {
  bool _isListening = false;

  late final OnnxRuntime _ort;
  late final OrtSession _melSession;
  late final OrtSession _embeddingSession;
  late final OrtSession _wakeWordSession;
  late final OrtSession _vadSession;

  // VAD state (LSTM hidden states) — shape [2, 1, 64]
  Float32List _vadH = Float32List(2 * 64);
  Float32List _vadC = Float32List(2 * 64);
  int _vadSampleRate = 16000;

  // Embedding parameters (from hey-buddy JS)
  static const int _embeddingWindowSize = 76;  // frames per window
  static const int _embeddingStride = 8;         // stride between windows
  static const int _melBins = 32;
  static const int _embeddingDim = 96;
  static const int _wakeWordFrames = 16;         // embeddings needed for wake word

  // Embedding buffer (96-dim vectors)
  final List<Float32List> _embeddingBuffer = [];

  // VAD thresholds (from hey-buddy defaults)
  final double _speechVadThreshold = 0.65;
  final double _silenceVadThreshold = 0.4;
  final int _negativeVadCount = 8;

  int _silentFrames = 0;
  bool _isSpeaking = false;
  bool _wakeWordFiredThisCycle = false;

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

  /// Called with VAD speech probability (0-1)
  void Function(double probability)? onSpeechProbability;

  /// Called with mel spectrogram frames for display [numFrames, 32]
  void Function(Float32List melFrames)? onMelSpectrogram;

  /// Audio buffer for continuous mel processing
  final List<double> _audioBuffer = [];
  /// Window size for mel spectrogram: 17280 samples = 1.08s at 16kHz → 105 frames → 4 embeddings
  static const int _melWindowSize = 17280;
  /// How many samples to advance after each mel processing
  static const int _melAdvance = 4740; // 4 windows × 790 stride

  /// Initialize ONNX sessions with model paths.
  Future<void> initialize({
    required String melSpectrogramPath,
    required String speechEmbeddingPath,
    required String wakeWordPath,
    required String vadModelPath,
  }) async {
    _ort = OnnxRuntime();

    _melSession = await _ort.createSession(melSpectrogramPath);
    _embeddingSession = await _ort.createSession(speechEmbeddingPath);
    _wakeWordSession = await _ort.createSession(wakeWordPath);
    _vadSession = await _ort.createSession(vadModelPath);

    debugPrint('ONNX pipeline initialized');
    debugPrint('  mel-spectrogram: ${await _melSession.getInputInfo()}');
    debugPrint('  speech-embedding: ${await _embeddingSession.getInputInfo()}');
    debugPrint('  wake-word: ${await _wakeWordSession.getInputInfo()}');
    debugPrint('  VAD: ${await _vadSession.getInputInfo()}');
  }

  void start() {
    debugPrint('[PIPELINE] START called');
    _isListening = true;
    _audioBuffer.clear();
    _embeddingBuffer.clear();
    _silentFrames = 0;
    _isSpeaking = false;
    _wakeWordFiredThisCycle = false;
    _setState(AudioState.listening);
  }

  void stop() {
    _isListening = false;
    _audioBuffer.clear();
    _setState(AudioState.idle);
  }

  /// Process a raw audio chunk (16-bit PCM mono 16kHz).
  /// Called from MicCaptureService for each audio buffer.
  void processAudioChunk(List<int> samples) {
    if (!_isListening || samples.isEmpty) return;

    // Normalize to float32 [-1, 1]
    final floatSamples = Float32List.fromList(
      samples.map((s) => s / 32768.0).toList(),
    );

    // Run ONNX pipeline synchronously (no async callbacks)
    _processChunkSync(floatSamples);
  }

  Future<void> _processChunkSync(Float32List samples) async {
    try {
      // ── 1. Add to rolling buffer ───────────────────────────────────────────
      _audioBuffer.addAll(samples);

      // ── 2. Run mel spectrogram when enough samples accumulated ────────────
      while (_audioBuffer.length >= _melWindowSize) {
        final window = Float32List(_melWindowSize);
        for (int i = 0; i < _melWindowSize; i++) {
          window[i] = _audioBuffer[i];
        }

        // Compute mel spectrogram (ONNX)
        final melFrames = await _runMelSpectrogram(window);
        if (melFrames != null) {
          // Defer callback to avoid callback-after-delete crash
          final melCopy = Float32List.fromList(melFrames);
          scheduleMicrotask(() => onMelSpectrogram?.call(melCopy));

          // Compute speech embedding
          final embedding = await _runSpeechEmbedding(melFrames);
          if (embedding != null) {
            _embeddingBuffer.add(embedding);
            debugPrint('[PIPELINE] Embedding computed, buffer size: ${_embeddingBuffer.length}');
          }
        }

        // Advance buffer
        _audioBuffer.removeRange(0, _melAdvance);
      }

      // ── 3. Wake Word (check when buffer has enough) ────
      if (_embeddingBuffer.length >= _wakeWordFrames && !_wakeWordFiredThisCycle) {
        final wakeProb = await _runWakeWord(_embeddingBuffer);
        debugPrint('[PIPELINE] Wake word check: buffer=${_embeddingBuffer.length}, prob=$wakeProb');
        if (wakeProb != null && wakeProb > 0.5) {
          debugPrint('[PIPELINE] WAKE WORD DETECTED! prob=$wakeProb');
          _wakeWordFiredThisCycle = true;
          _setState(AudioState.wakeWord);
          onWakeWord?.call('hey buddy');
          _embeddingBuffer.clear();
          // Reset after 2 seconds to allow detecting again
          Future.delayed(const Duration(seconds: 2), () {
            _wakeWordFiredThisCycle = false;
          });
        } else {
          // Reset flag if probability drops
          _wakeWordFiredThisCycle = false;
        }
      }
    } catch (e) {
      debugPrint('[PIPELINE] Error in chunk processing: $e');
    }
  }

  /// Run mel spectrogram and apply post-processing (/10 + 2 from JS reference).
  /// Returns flat Float32List of shape [numFrames, 32] — one row per frame.
  Future<Float32List?> _runMelSpectrogram(Float32List samples) async {
    try {
      final input = await OrtValue.fromList(samples, [1, samples.length]);
      final Map<String, OrtValue> outputs = await _melSession.run({'input': input});
      final OrtValue? output = outputs['output'];
      input.dispose();
      if (output == null) return null;

      final flat = await output.asFlattenedList();
      // Output shape: [1, 1, time, 32] → time is at index 2
      final timeDim = output.shape[2];
      output.dispose();

      // Apply JS post-processing: datum / 10.0 + 2.0
      final result = Float32List(timeDim * _melBins);
      for (int i = 0; i < flat.length; i++) {
        result[i] = flat[i] / 10.0 + 2.0;
      }

      return result;
    } catch (e) {
      debugPrint('[PIPELINE] Mel spectrogram error: $e');
      return null;
    }
  }

  /// Run speech embedding: sliding window over mel frames → 96-dim embedding per window.
  Future<Float32List?> _runSpeechEmbedding(Float32List melFrames) async {
    try {
      final numFrames = melFrames.length ~/ _melBins;
      if (numFrames < _embeddingWindowSize) return null;

      // Take the first window of 76 frames - ONNX expects [batch, 76, 32, 1] = 4D
      final window = Float32List(_embeddingWindowSize * _melBins);
      for (int i = 0; i < _embeddingWindowSize * _melBins; i++) {
        window[i] = melFrames[i];
      }

      final input = await OrtValue.fromList(window, [1, _embeddingWindowSize, _melBins, 1]);
      final Map<String, OrtValue> outputs = await _embeddingSession.run({'input_1': input});
      final OrtValue? output = outputs['output'];
      input.dispose();
      if (output == null) return null;

      final flat = await output.asFlattenedList();
      output.dispose();

      // Return 96-dim embedding
      return Float32List.fromList(flat.take(_embeddingDim).cast<double>().toList());
    } catch (e) {
      debugPrint('[PIPELINE] Speech embedding error: $e');
      return null;
    }
  }

  /// Run wake word detection: 16 embeddings → single probability.
  Future<double?> _runWakeWord(List<Float32List> embeddings) async {
    try {
      if (embeddings.length < _wakeWordFrames) return null;

      // Build input: [1, 16, 96]
      final inputData = Float32List(_wakeWordFrames * _embeddingDim);
      for (int i = 0; i < _wakeWordFrames; i++) {
        for (int j = 0; j < _embeddingDim; j++) {
          inputData[i * _embeddingDim + j] = embeddings[i][j];
        }
      }

      final input = await OrtValue.fromList(inputData, [1, _wakeWordFrames, _embeddingDim]);
      final Map<String, OrtValue> outputs = await _wakeWordSession.run({'input': input});
      final OrtValue? output = outputs['output'];
      input.dispose();
      if (output == null) return null;

      final flat = await output.asFlattenedList();
      output.dispose();

      return flat.isNotEmpty ? flat[0] : null;
    } catch (e) {
      debugPrint('[PIPELINE] Wake word error: $e');
      return null;
    }
  }

  void dispose() {
    stop();
    // Note: flutter_onnxruntime handles cleanup automatically
    // Sessions are disposed when the runtime is disposed
    _stateController.close();
  }
}