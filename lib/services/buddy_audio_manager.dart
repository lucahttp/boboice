import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'audio_pipeline.dart' show AudioState;
import 'onnx_pipeline.dart';
import 'mic_capture_service.dart';

class BuddyAudioManager {
  final MicCaptureService _mic = MicCaptureService();
  OnnxPipeline? _pipeline;
  final _melController = StreamController<Float32List>.broadcast();
  
  Stream<Float32List> get melSpectrogramStream => _melController.stream;
  
  final _stateController = StreamController<AudioState>.broadcast();
  Stream<AudioState> get stateStream => _stateController.stream;

  Function(String)? onWakeWord;
  Function(String)? onTranscription;

  bool _wakeWordDetected = false;
  List<double> _audioBuffer = [];
  List<int> _sampleBuffer = []; // Store original samples for ASR
  
  StreamSubscription? _micSub;

  Future<void> initialize({
    required String wakeWordPath,
    required String asrTokensPath,
    required String asrEncoderPath,
    required String asrDecoderPath,
    required String asrJoinerPath,
    required String melSpectrogramPath,
    required String speechEmbeddingPath,
    required String vadModelPath,
  }) async {
    // Init ONNX pipeline for wake word detection
    try {
      _pipeline = OnnxPipeline();
      
      _pipeline!.onSpeechProbability = (prob) {
        debugPrint('[PIPELINE] VAD prob: $prob');
      };
      
      _pipeline!.onMelSpectrogram = (frames) {
        _melController.add(frames);
      };
      
      _pipeline!.onWakeWord = (phrase) {
        debugPrint('[PIPELINE] Wake word fired: $phrase');
        if (!_wakeWordDetected) {
          _wakeWordDetected = true;
          _audioBuffer.clear();
          _sampleBuffer.clear();
          _stateController.add(AudioState.listening);
          onWakeWord?.call(phrase);
        }
      };
      
      await _pipeline!.initialize(
        melSpectrogramPath: melSpectrogramPath,
        speechEmbeddingPath: speechEmbeddingPath,
        wakeWordPath: wakeWordPath,
        vadModelPath: vadModelPath,
      );
      
      debugPrint('OnnxPipeline: Wake word model loaded.');
    } catch (e) {
      debugPrint('OnnxPipeline init error: $e');
    }
  }

  Future<void> start() async {
    _stateController.add(AudioState.idle);
    await _mic.init();
    await _mic.start();
    _pipeline?.start();
    _micSub = _mic.pcmStream.listen(_processPcmChunks);
    debugPrint('[Audio] Mic stream started with ONNX pipeline.');
  }

  void _processPcmChunks(List<int> intSamples) {
    // Feed raw PCM to ONNX pipeline for wake word detection
    _pipeline?.processAudioChunk(intSamples);
    
    // Buffer audio after wake word
    if (_wakeWordDetected) {
      _sampleBuffer.addAll(intSamples);
      
      // Check for silence (energy-based fallback while ONNX processes)
      double energy = 0.0;
      for (var s in intSamples) {
        final f = s / 32768.0;
        energy += f * f;
      }
      energy /= intSamples.length;
      final isSilent = energy < 0.0005;
      
      if (isSilent) {
        // Enough silence - run ASR
        _wakeWordDetected = false;
        _stateController.add(AudioState.processing);
        _runWhisperAsr();
      }
      
      // Max 30 seconds
      if (_sampleBuffer.length > 16000 * 30) {
        debugPrint('[Audio] Max recording length reached');
        _wakeWordDetected = false;
        _sampleBuffer.clear();
        _stateController.add(AudioState.idle);
      }
    }
  }

  void _runWhisperAsr() {
    if (_sampleBuffer.isEmpty) {
      _stateController.add(AudioState.idle);
      return;
    }
    
    debugPrint('[Audio] Running Whisper ASR on ${_sampleBuffer.length} samples');
    // TODO: Wire up Whisper ASR via flutter_onnxruntime
    // For now, just reset state
    _sampleBuffer.clear();
    _stateController.add(AudioState.idle);
  }

  void dispose() {
    _micSub?.cancel();
    _mic.dispose();
    _pipeline?.stop();
    _pipeline?.dispose();
    _melController.close();
    _stateController.close();
  }
}
