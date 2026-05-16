import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

/// Offline Whisper transcription using sherpa_onnx.
/// This uses the C++ optimized whisper.cpp/ONNX bindings for maximum performance
/// and is the most optimal way to run Whisper locally on device.
class SherpaWhisperService {
  OfflineRecognizer? _recognizer;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  /// Initialize Sherpa-ONNX Whisper recognizer
  Future<void> initialize({
    required String encoderPath,
    required String decoderPath,
    required String tokensPath,
  }) async {
    if (_isInitialized) return;
    
    debugPrint('SherpaWhisperService: Initializing with models:');
    debugPrint('  Encoder: $encoderPath');
    debugPrint('  Decoder: $decoderPath');
    debugPrint('  Tokens: $tokensPath');

    try {
      final config = OfflineRecognizerConfig(
        model: OfflineModelConfig(
          whisper: OfflineWhisperModelConfig(
            encoder: encoderPath,
            decoder: decoderPath,
          ),
          tokens: tokensPath,
          modelType: 'whisper',
          numThreads: 4,
          debug: false,
        ),
        featConfig: FeatureExtractorConfig(
          sampleRate: 16000,
          featureDim: 80,
        ),
      );

      _recognizer = OfflineRecognizer(config: config);
      _isInitialized = true;
      debugPrint('SherpaWhisperService: Initialized successfully.');
    } catch (e) {
      debugPrint('SherpaWhisperService initialization failed: $e');
    }
  }

  /// Transcribe a buffer of 16-bit PCM mono 16kHz audio.
  Future<String?> transcribe(List<int> pcm16Samples) async {
    if (!_isInitialized || _recognizer == null) {
      debugPrint('SherpaWhisperService: Not initialized');
      return null;
    }
    
    if (pcm16Samples.isEmpty) return null;

    // Convert List<int> (16-bit PCM) to Float32List (range -1.0 to 1.0)
    // sherpa-onnx expects float32 samples in the range [-1, 1]
    final floatSamples = Float32List(pcm16Samples.length);
    for (int i = 0; i < pcm16Samples.length; i++) {
      // Int16 mapping to float
      int sample = pcm16Samples[i];
      if (sample > 32767) sample -= 65536;
      floatSamples[i] = sample / 32768.0;
    }

    try {
      debugPrint('SherpaWhisperService: Transcribing \${floatSamples.length} samples...');
      
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(sampleRate: 16000, samples: floatSamples);
      
      _recognizer!.decode(stream);
      
      final result = _recognizer!.getResult(stream);
      stream.free();
      
      final text = result.text.trim();
      debugPrint('SherpaWhisperService: Result = "\$text"');
      
      return text.isNotEmpty ? text : null;
    } catch (e) {
      debugPrint('SherpaWhisperService transcription error: $e');
      return null;
    }
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _isInitialized = false;
  }
}
