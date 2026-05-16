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
  static const int _embeddingWindowStride = 8; // stride between windows
  static const int _melBins = 32;
  static const int _embeddingDim = 96;
  static const int _wakeWordFrames = 16;         // embeddings needed for wake word

  // Embedding buffer (96-dim vectors) - FIXED SIZE sliding window like JS
  // maxEmbeddings = wakeWordEmbeddingFrames / numFramesPerEmbedding = 16 / 4 = 4
  static const int _maxEmbeddingBufferSize = 4;  // embeddings to fill 16 frames
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

  /// Called when VAD detects speech start
  void Function()? onSpeechStart;

  /// Called when VAD detects speech end
  void Function()? onSpeechEnd;

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

      // ── 2. Run VAD on last batch of audio (like JS batchInterval = 1920 samples = 120ms)
      // This matches the JS code: lastBatch = audio.subarray(audio.length - batchIntervalSamples)
      if (_audioBuffer.length >= 1920) {
        final lastBatch = _audioBuffer.sublist(_audioBuffer.length - 1920);
        final speechProb = await _runVad(lastBatch);
        
        bool justStartedSpeaking = false;
        bool justStoppedSpeaking = false;
        
        if (speechProb > _speechVadThreshold && !_isSpeaking) {
          _isSpeaking = true;
          _silentFrames = 0;
          justStartedSpeaking = true;
        } else if (speechProb < _silenceVadThreshold && _isSpeaking) {
          _silentFrames++;
          if (_silentFrames >= _negativeVadCount) {
            _isSpeaking = false;
            justStoppedSpeaking = true;
          }
        } else if (speechProb >= _silenceVadThreshold) {
          // Reset silence counter if it's above silence threshold
          _silentFrames = 0;
        }
        
        onSpeechProbability?.call(speechProb);
        if (justStartedSpeaking) onSpeechStart?.call();
        if (justStoppedSpeaking) onSpeechEnd?.call();
      }

      // ── 3. Run mel spectrogram when enough samples accumulated ────────────
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
          Future.microtask(() => onMelSpectrogram?.call(melCopy));

          // Compute ALL embeddings using BATCHED inference (same as hey-buddy JS)
          final embeddings = await _runSpeechEmbeddingBatch(melFrames);
          if (embeddings != null) {
            for (final emb in embeddings) {
              _embeddingBuffer.add(emb);
            }
            // Trim buffer to max size (like JS: if length > maxEmbeddings, shift)
            while (_embeddingBuffer.length > _maxEmbeddingBufferSize) {
              _embeddingBuffer.removeAt(0);
            }
            debugPrint('[PIPELINE] Added ${embeddings.length} embeddings, buffer size: ${_embeddingBuffer.length}');
          }
        }

        // Advance buffer
        _audioBuffer.removeRange(0, _melAdvance);
      }

      // Restore proper default threshold (hey-buddy JS default is 0.5)
      // ONLY check wake word when:
      // 1. Buffer is full (4 embeddings = 16 frames like JS)
      // 2. isSpeaking is true (VAD detected speech)
      // 3. Wake word hasn't already fired this cycle
      final shouldCheckWakeWord = _embeddingBuffer.length >= _maxEmbeddingBufferSize && !_wakeWordFiredThisCycle && _isSpeaking;
      
      if (shouldCheckWakeWord) {
        // Build combined embedding [1, 16, 96] from buffer like JS embeddingBufferArrayToEmbedding
        final combinedEmbedding = Float32List(_wakeWordFrames * _embeddingDim);
        for (int i = 0; i < _embeddingBuffer.length; i++) {
          for (int j = 0; j < _embeddingDim; j++) {
            combinedEmbedding[i * _embeddingDim + j] = _embeddingBuffer[i][j];
          }
        }
        
        final wakeProb = await _runWakeWordFromCombined(combinedEmbedding);
        debugPrint('[PIPELINE] Wake word check: buffer=${_embeddingBuffer.length}, prob=$wakeProb, speaking=$_isSpeaking');
        
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
      final timeDim = output.shape[2];
      final melBins = output.shape[3];
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

  /// Extract all embeddings via sliding window over mel frames.
  Future<List<Float32List>?> _runSpeechEmbeddingBatch(Float32List melFrames) async {
    try {
      final numFrames = melFrames.length ~/ _melBins;
      debugPrint('[PIPELINE] _runSpeechEmbeddingBatch: numFrames=$numFrames');
      if (numFrames < _embeddingWindowSize) return null;

      // Calculate number of batches (same formula as JS)
      final numTruncatedFrames = numFrames - (numFrames - _embeddingWindowSize) % _embeddingWindowStride;
      final numBatches = (numTruncatedFrames - _embeddingWindowSize) ~/ _embeddingWindowStride + 1;
      debugPrint('[PIPELINE] numBatches=$numBatches (numFrames=$numFrames, windowSize=$_embeddingWindowSize, stride=$_embeddingWindowStride)');

      // Build batched input: [numBatches, 76, 32, 1]
      final batchedInput = Float32List(numBatches * _embeddingWindowSize * _melBins);
      int windowStart = 0;
      int batchIdx = 0;
      while (windowStart + _embeddingWindowSize <= numFrames && batchIdx < numBatches) {
        for (int i = 0; i < _embeddingWindowSize * _melBins; i++) {
          batchedInput[batchIdx * _embeddingWindowSize * _melBins + i] = 
              melFrames[windowStart * _melBins + i];
        }
        windowStart += _embeddingWindowStride;
        batchIdx++;
      }

      final input = await OrtValue.fromList(batchedInput, [numBatches, _embeddingWindowSize, _melBins, 1]);
      final Map<String, OrtValue> outputs = await _embeddingSession.run({'input_1': input});

      for (final key in outputs.keys) {
        debugPrint('[PIPELINE] Embedding output key: "$key", shape: ${outputs[key]!.shape}');
      }

      final OrtValue? output = outputs['output'] ?? outputs['output_1'] ?? outputs['conv2d_19'];
      input.dispose();
      if (output == null) {
        debugPrint('[PIPELINE] Embedding output is NULL - no output key found');
        return null;
      }

      final flat = await output.asFlattenedList();
      debugPrint('[PIPELINE] Embedding output shape: ${output.shape}, flatLen=${flat.length}');
      output.dispose();

      // Output is [numBatches, 1, 1, 96] - extract each 96-dim embedding
      final embeddings = <Float32List>[];
      for (int i = 0; i < numBatches; i++) {
        final startIdx = i * _embeddingDim;
        final emb = Float32List.fromList(flat.sublist(startIdx, startIdx + _embeddingDim).cast<double>().toList());
        embeddings.add(emb);
      }
      return embeddings;
    } catch (e) {
      debugPrint('[PIPELINE] Speech embedding batch error: $e');
      return null;
    }
  }

  /// Run wake word detection from pre-combined [1, 16, 96] tensor.
  Future<double?> _runWakeWordFromCombined(Float32List combinedEmbedding) async {
    try {
      final input = await OrtValue.fromList(combinedEmbedding, [1, _wakeWordFrames, _embeddingDim]);
      final Map<String, OrtValue> outputs = await _wakeWordSession.run({'input': input});
      final OrtValue? output = outputs['output'];
      input.dispose();
      if (output == null) return null;

      final flat = await output.asFlattenedList();
      debugPrint('[PIPELINE] Wake word output shape: ${output.shape}, values: ${flat.sublist(0, flat.length > 10 ? 10 : flat.length)}');
      output.dispose();

      return flat.isNotEmpty ? flat[0] : null;
    } catch (e) {
      debugPrint('[PIPELINE] Wake word error: $e');
      return null;
    }
  }

  /// Run VAD on a small slice of audio (like JS batchInterval = 1920 samples = 120ms).
  /// Returns speech probability (0-1).
  Future<double> _runVad(List<double> audioSamples) async {
    try {
      final inputData = Float32List.fromList(audioSamples);
      final input = await OrtValue.fromList(inputData, [1, audioSamples.length]);
      // sr is scalar int64 - use Int64List for proper type
      final srData = Int64List.fromList([_vadSampleRate]);
      final sr = await OrtValue.fromList(srData, []);
      final h = await OrtValue.fromList(_vadH, [2, 1, 64]);
      final c = await OrtValue.fromList(_vadC, [2, 1, 64]);
      
      final outputs = await _vadSession.run({
        'input': input,
        'sr': sr,
        'h': h,
        'c': c,
      });
      input.dispose();
      sr.dispose();
      h.dispose();
      c.dispose();
      
      final OrtValue? output = outputs['output'];
      if (output == null) return 0.0;
      
      final prob = (await output.asFlattenedList())[0];
      
      // Update VAD state from 'hn' and 'cn' outputs if available
      if (outputs.containsKey('hn')) {
        final hn = await outputs['hn']!.asFlattenedList();
        for (int i = 0; i < hn.length && i < _vadH.length; i++) {
          _vadH[i] = hn[i];
        }
      }
      if (outputs.containsKey('cn')) {
        final cn = await outputs['cn']!.asFlattenedList();
        for (int i = 0; i < cn.length && i < _vadC.length; i++) {
          _vadC[i] = cn[i];
        }
      }
      
      output.dispose();
      return prob.toDouble();
    } catch (e) {
      debugPrint('[PIPELINE] VAD error: $e');
      return 0.0;
    }
  }

  void dispose() {
    stop();
    // Note: flutter_onnxruntime handles cleanup automatically
    // Sessions are disposed when the runtime is disposed
    _stateController.close();
  }
}