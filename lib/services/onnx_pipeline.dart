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

    // Run ONNX pipeline asynchronously
    _processChunkAsync(floatSamples);
  }

  Future<void> _processChunkAsync(Float32List floatSamples) async {
    // Accumulate all incoming audio for continuous processing
    for (final s in floatSamples) { _audioBuffer.add(s); }

    // ── Run VAD on every chunk (real-time, doesn't need accumulation) ──
    final lastStart = (floatSamples.length - 512).clamp(0, floatSamples.length);
    final vadChunk = floatSamples.sublist(lastStart);
    final vadProb = await _runVad(vadChunk);
    onSpeechProbability?.call(vadProb);

    // Update VAD state machine
    final hasSpeech = vadProb > _speechVadThreshold;
    final hasSilence = vadProb < _silenceVadThreshold;

    if (!hasSpeech && hasSilence) {
      _silentFrames++;
      if (_isSpeaking && _silentFrames > _negativeVadCount) {
        _isSpeaking = false;
        _silentFrames = 0;
        _embeddingBuffer.clear(); // Reset on silence
        _setState(AudioState.idle);
      }
    } else {
      _silentFrames = 0;
      if (!_isSpeaking && hasSpeech) {
        _isSpeaking = true;
        _wakeWordFiredThisCycle = false;
        _setState(AudioState.processing);
      }
    }

    // ── Run mel + embedding + wake word continuously ──
    // Process when we have a full window (17280 samples = 1.08s)
    if (_audioBuffer.length < _melWindowSize) return;

    // Take a window and advance by _melAdvance (4740 samples = 4 embeddings worth)
    final windowSamples = Float32List.fromList(_audioBuffer.sublist(0, _melWindowSize));

    // ── 1. Mel Spectrogram (with post-process: /10 + 2) ───────────────
    final melFrames = await _runMelSpectrogram(windowSamples);
    if (melFrames == null) return;
    final numFrames = melFrames.length ~/ _melBins;

    // ── 2. Speech Embedding (batch all windows in ONE ONNX call) ──────
    final embeddings = await _runEmbeddingBatch(melFrames, numFrames);
    if (embeddings.isEmpty) return;

    // Add all embeddings to buffer, maintaining rolling window of 16
    for (final emb in embeddings) {
      _embeddingBuffer.add(emb);
      if (_embeddingBuffer.length > _wakeWordFrames) {
        _embeddingBuffer.removeAt(0);
      }
    }

    // Advance buffer by removing processed samples
    if (_audioBuffer.length > _melAdvance) {
      _audioBuffer.removeRange(0, _melAdvance);
    }

    // ── 3. Wake Word (check when buffer has enough) ────
    if (_embeddingBuffer.length >= _wakeWordFrames && !_wakeWordFiredThisCycle) {
      final wakeProb = await _runWakeWord(_embeddingBuffer);
      if (wakeProb != null && wakeProb > 0.5) {
        _wakeWordFiredThisCycle = true;
        _setState(AudioState.wakeWord);
        onWakeWord?.call('hey buddy');
        _embeddingBuffer.clear();
      }
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
      for (int i = 0; i < flat.length && i < result.length; i++) {
        result[i] = (flat[i] as num).toDouble() / 10.0 + 2.0;
      }

      // Send mel frames for display
      onMelSpectrogram?.call(result);
      return result;
    } catch (e) {
      debugPrint('Mel spectrogram error: $e');
      return null;
    }
  }

  /// Run speech embedding on ALL windows in a single ONNX batch call.
  /// melFrames: flat [numFrames, 32] (post-processed mel spectrogram)
  /// Returns list of 96-dim embedding vectors, one per window.
  Future<List<Float32List>> _runEmbeddingBatch(Float32List melFrames, int numFrames) async {
    if (numFrames < _embeddingWindowSize) return [];

    // Calculate number of windows (matching JS logic)
    final numTruncatedFrames = numFrames - (numFrames - _embeddingWindowSize) % _embeddingStride;
    final numBatches = ((numTruncatedFrames - _embeddingWindowSize) / _embeddingStride + 1).toInt();

    if (numBatches <= 0) return [];

    try {
      // Build batched input [numBatches, 76, 32, 1]
      final batchData = Float32List(numBatches * _embeddingWindowSize * _melBins);
      for (int b = 0; b < numBatches; b++) {
        final windowStart = b * _embeddingStride;
        for (int i = 0; i < _embeddingWindowSize; i++) {
          final frameIdx = windowStart + i;
          for (int j = 0; j < _melBins; j++) {
            batchData[b * (_embeddingWindowSize * _melBins) + i * _melBins + j] =
                melFrames[frameIdx * _melBins + j];
          }
        }
      }

      final input = await OrtValue.fromList(batchData, [numBatches, _embeddingWindowSize, _melBins, 1]);
      final Map<String, OrtValue> outputs = await _embeddingSession.run({'input_1': input});
      final OrtValue? output = outputs['conv2d_19'];
      input.dispose();
      if (output == null) return [];

      final flat = await output.asFlattenedList();
      output.dispose();

      // Extract each embedding [96]
      final embeddings = <Float32List>[];
      for (int b = 0; b < numBatches; b++) {
        final emb = Float32List(_embeddingDim);
        for (int i = 0; i < _embeddingDim; i++) {
          emb[i] = (flat[b * _embeddingDim + i] as num).toDouble();
        }
        embeddings.add(emb);
      }
      return embeddings;
    } catch (e) {
      debugPrint('Speech embedding error: $e');
      return [];
    }
  }

  /// Run wake word on the full embedding buffer (16 × 96-dim → [1, 16, 96]).
  Future<double?> _runWakeWord(List<Float32List> embeddings) async {
    if (embeddings.length < _wakeWordFrames) return null;
    try {
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
      final prob = (flat[0] as num).toDouble();
      output.dispose();
      return prob;
    } catch (e) {
      debugPrint('Wake word error: $e');
      return null;
    }
  }

  Future<double> _runVad(Float32List samples) async {
    try {
      // Silero VAD: input[1, N], sr[int64], h[2, 1, 64], c[2, 1, 64]
      final input = await OrtValue.fromList(samples, [1, samples.length]);
      // sr must be int64 per model spec (elem_type=7)
      final srData = Int64List.fromList([_vadSampleRate]);
      final sr = await OrtValue.fromList(srData, []);
      final h = await OrtValue.fromList(_vadH, [2, 1, 64]);
      final c = await OrtValue.fromList(_vadC, [2, 1, 64]);

      final Map<String, OrtValue> outputs = await _vadSession.run({
        'input': input,
        'sr': sr,
        'h': h,
        'c': c,
      });

      final OrtValue? output = outputs['output'];
      final OrtValue? hn = outputs['hn'];
      final OrtValue? cn = outputs['cn'];

      double prob = 0.5;
      if (output != null) {
        final flat = await output.asFlattenedList();
        if (flat.isNotEmpty) {
          prob = (flat[0] as num).toDouble().clamp(0.0, 1.0);
        }
      }

      // Update LSTM states
      if (hn != null) {
        final hnFlat = await hn.asFlattenedList();
        for (int i = 0; i < _vadH.length && i < hnFlat.length; i++) {
          _vadH[i] = (hnFlat[i] as num).toDouble();
        }
      }
      if (cn != null) {
        final cnFlat = await cn.asFlattenedList();
        for (int i = 0; i < _vadC.length && i < cnFlat.length; i++) {
          _vadC[i] = (cnFlat[i] as num).toDouble();
        }
      }

      input.dispose();
      sr.dispose();
      h.dispose();
      c.dispose();
      return prob;
    } catch (e) {
      debugPrint('VAD error: $e');
      return 0.5;
    }
  }

  void dispose() {
    stop();
    try {
      _melSession.close();
      _embeddingSession.close();
      _wakeWordSession.close();
      _vadSession.close();
    } catch (_) {
      // Sessions not initialized — ignore
    }
    _stateController.close();
  }
}
