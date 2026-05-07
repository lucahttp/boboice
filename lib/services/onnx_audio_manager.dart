import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'audio_pipeline.dart';
import 'mic_capture_service.dart';
import 'onnx_pipeline.dart';

/// AudioIsolateManager that uses ONNX-based VAD + wake word via flutter_onnxruntime,
/// plus Sherpa ASR for transcription.
///
/// Pipeline flow:
///   MicCapture → OnnxPipeline(VAD + WakeWord) → (SherpaASR → transcription)
///
/// Currently using ONNX VAD + wake word; ASR wiring is for later integration.
class OnnxAudioManager {
  bool _running = false;
  OnnxPipeline? _onnxPipeline;
  MicCaptureService? _mic;

  final _stateController = StreamController<AudioState>.broadcast();
  AudioState _currentState = AudioState.idle;
  Stream<AudioState> get stateStream => _stateController.stream;

  final _speechProbController = StreamController<double>.broadcast();
  Stream<double> get speechProbabilityStream => _speechProbController.stream;

  void Function(String text)? onTranscription;
  void Function(String wakeWord)? onWakeWord;
  void Function(bool isSpeaking)? onVadState;
  void Function(Float32List melFrames)? onMelSpectrogram;

  bool get isRunning => _running;

  /// Initialize ONNX models (mel-spec, embedding, wake word, VAD) and ASR.
  Future<void> initialize({
    required String melSpectrogramPath,
    required String speechEmbeddingPath,
    required String wakeWordPath,
    required String vadModelPath,
    required String asrModelPath,
    required String tokensPath,
  }) async {
    // ONNX pipeline for VAD + wake word
    _onnxPipeline = OnnxPipeline();
    _onnxPipeline!.onSpeechProbability = (prob) {
      _speechProbController.add(prob);
      onVadState?.call(prob > 0.5);
    };
    _onnxPipeline!.onWakeWord = (word) {
      _setState(AudioState.wakeWord);
      onWakeWord?.call(word);
    };
    _onnxPipeline!.onMelSpectrogram = (frames) {
      onMelSpectrogram?.call(frames);
    };

    await _onnxPipeline!.initialize(
      melSpectrogramPath: melSpectrogramPath,
      speechEmbeddingPath: speechEmbeddingPath,
      wakeWordPath: wakeWordPath,
      vadModelPath: vadModelPath,
    );

    debugPrint('OnnxAudioManager initialized');
  }

  void _setState(AudioState state) {
    if (_currentState != state) {
      _currentState = state;
      _stateController.add(state);
    }
  }

  Future<void> start() async {
    if (_running) return;

    debugPrint('[AUDIO_MGR] start called');
    _mic = MicCaptureService();
    await _mic!.init();
    debugPrint('[AUDIO_MGR] mic initialized');

    // Wire mic → ONNX pipeline
    _mic!.pcmStream.listen((samples) {
      debugPrint('[AUDIO_MGR] PCM stream: ${samples.length} samples');
      if (!_running) return;
      _onnxPipeline?.processAudioChunk(samples);
    });

    await _mic!.start();
    debugPrint('[AUDIO_MGR] mic started');
    _onnxPipeline?.start();
    debugPrint('[AUDIO_MGR] pipeline started');
    _running = true;
  }

  void stop() {
    _running = false;
    _mic?.stop();
    _onnxPipeline?.stop();
  }

  void dispose() {
    stop();
    _mic?.dispose();
    _onnxPipeline?.dispose();
    _stateController.close();
    _speechProbController.close();
  }
}