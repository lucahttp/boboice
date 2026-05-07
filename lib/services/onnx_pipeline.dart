import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'audio_pipeline.dart';

/// ONNX-based audio pipeline that mirrors hey-buddy's JavaScript implementation.
/// Uses flutter_onnxruntime to run ONNX models natively.
///
/// Pipeline (per audio chunk):
///   1. mel-spectrogram.onnx: audio[1, N] → mel[time, 1, 97, 32]
///   2. speech-embedding.onnx: mel[N, 76, 32, 1] → embedding[1, 1, 1, 96]
///   3. hey-buddy.onnx: embedding[1, 16, 96] → wake_word_prob[1, 1]
///   4. SileroVAD: audio + states → speech_probability
///
/// Reference: https://github.com/painebenjamin/hey-buddy/blob/main/src/js/src/hey-buddy.js
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

  // Wake word state
  final List<Float32List> _embeddingBuffer = [];
  final int _embeddingWindowSize = 16; // number of embeddings for wake word

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
    _isListening = true;
    _setState(AudioState.listening);
  }

  void stop() {
    _isListening = false;
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
    // ── 1. Mel Spectrogram ─────────────────────────────────────────────
    final melResult = await _runMelSpectrogram(floatSamples);
    if (melResult == null) return;
    final numFrames = melResult.length ~/ (97 * 32);

    // ── 2. Speech Embedding + Wake Word ───────────────────────────────
    for (int frameIdx = 0; frameIdx < numFrames; frameIdx++) {
      final frameOffset = frameIdx * 97 * 32;

      final embedding = await _runSpeechEmbeddingFrame(melResult, frameOffset);
      if (embedding == null) continue;

      _embeddingBuffer.add(embedding);
      if (_embeddingBuffer.length > _embeddingWindowSize) {
        _embeddingBuffer.removeAt(0);
      }

      if (_embeddingBuffer.length == _embeddingWindowSize && !_wakeWordFiredThisCycle) {
        final wakeProb = await _runWakeWord(_embeddingBuffer);
        if (wakeProb != null && wakeProb > 0.5) {
          _wakeWordFiredThisCycle = true;
          _setState(AudioState.wakeWord);
          onWakeWord?.call('hey buddy');
        }
      }
    }

    // ── 3. Silero VAD ─────────────────────────────────────────────────
    // Run on last 512 samples (32ms)
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
        _setState(AudioState.processing);
      }
    } else {
      _silentFrames = 0;
      if (!_isSpeaking && hasSpeech) {
        _isSpeaking = true;
        _wakeWordFiredThisCycle = false; // reset after user starts speaking
        _setState(AudioState.listening);
      }
    }
  }

  Future<Float32List?> _runMelSpectrogram(Float32List samples) async {
    try {
      final input = await OrtValue.fromList(samples, [1, samples.length]);
      final Map<String, OrtValue> outputs = await _melSession.run({'input': input});
      final OrtValue? output = outputs['output'];
      input.dispose();
      if (output == null) return null;

      final flat = await output.asFlattenedList();
      final timeDim = output.shape[0];
      final result = Float32List(timeDim * 97 * 32);
      for (int i = 0; i < flat.length && i < result.length; i++) {
        result[i] = (flat[i] as num).toDouble();
      }
      output.dispose();
      return result;
    } catch (e) {
      debugPrint('Mel spectrogram error: $e');
      return null;
    }
  }

  /// Run speech embedding on a single frame.
  /// melResult: flat Float32List of all time frames, each frame = 97*32 values
  Future<Float32List?> _runSpeechEmbeddingFrame(Float32List melResult, int frameOffset) async {
    try {
      final inputData = Float32List(76 * 32);
      for (int i = 0; i < 76 * 32; i++) {
        inputData[i] = melResult[frameOffset + i];
      }

      final input = await OrtValue.fromList(inputData, [1, 76, 32, 1]);
      final Map<String, OrtValue> outputs = await _embeddingSession.run({'input_1': input});
      final OrtValue? output = outputs['conv2d_19'];
      input.dispose();
      if (output == null) return null;

      final flat = await output.asFlattenedList();
      final result = Float32List(96);
      for (int i = 0; i < 96 && i < flat.length; i++) {
        result[i] = (flat[i] as num).toDouble();
      }
      output.dispose();
      return result;
    } catch (e) {
      debugPrint('Speech embedding error: $e');
      return null;
    }
  }

  Future<double?> _runWakeWord(List<Float32List> embeddings) async {
    try {
      final inputData = Float32List(16 * 96);
      for (int i = 0; i < 16; i++) {
        for (int j = 0; j < 96; j++) {
          inputData[i * 96 + j] = embeddings[i][j];
        }
      }

      final input = await OrtValue.fromList(inputData, [1, 16, 96]);
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
