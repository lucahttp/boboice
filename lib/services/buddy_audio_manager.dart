import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'audio_pipeline.dart' show AudioState;
import 'onnx_pipeline.dart';
import 'mic_capture_service.dart';
import 'sherpa_whisper_service.dart';

class BuddyAudioManager {
  final MicCaptureService _mic = MicCaptureService();
  OnnxPipeline? _pipeline;
  final SherpaWhisperService _asrService = SherpaWhisperService();
  final _melController = StreamController<Float32List>.broadcast();
  
  Stream<Float32List> get melSpectrogramStream => _melController.stream;
  
  final _stateController = StreamController<AudioState>.broadcast();
  Stream<AudioState> get stateStream => _stateController.stream;

  Function(String)? onWakeWord;
  Function(String)? onTranscription;
  Function(List<int> samples)? onAudioReady; // fires when wake+silence captured
  Function(List<int>)? onAudioCaptured; // fires on each chunk during capture

  bool _wakeWordDetected = false;
  List<double> _audioBuffer = [];
  List<int> _sampleBuffer = []; // Store original samples for ASR
  final List<int> _preWakeWordBuffer = [];
  
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
          // Include the past ~1.08 seconds that contained the wake word
          _sampleBuffer.addAll(_preWakeWordBuffer);
          _preWakeWordBuffer.clear();
          
          _stateController.add(AudioState.listening);
          onWakeWord?.call(phrase);
        }
      };

      _pipeline!.onSpeechEnd = () {
        if (_wakeWordDetected) {
          debugPrint('[Audio] Speech ended via VAD, processing recording');
          _wakeWordDetected = false;
          _stateController.add(AudioState.processing);
          _processRecordedAudio();
        }
      };
      
      await _pipeline!.initialize(
        melSpectrogramPath: melSpectrogramPath,
        speechEmbeddingPath: speechEmbeddingPath,
        wakeWordPath: wakeWordPath,
        vadModelPath: vadModelPath,
      );
      
      debugPrint('OnnxPipeline: Wake word model loaded.');

      await _asrService.initialize(
        encoderPath: asrEncoderPath,
        decoderPath: asrDecoderPath,
        tokensPath: asrTokensPath,
      );
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
    
    if (_wakeWordDetected) {
      _sampleBuffer.addAll(intSamples);
      onAudioCaptured?.call(intSamples);
      
      // Max 30 seconds
      if (_sampleBuffer.length > 16000 * 30) {
        debugPrint('[Audio] Max recording length reached');
        _wakeWordDetected = false;
        _stateController.add(AudioState.processing);
        _processRecordedAudio();
      }
    } else {
      // Keep a rolling buffer of ~1.08s (17280 samples)
      _preWakeWordBuffer.addAll(intSamples);
      if (_preWakeWordBuffer.length > 17280) {
        _preWakeWordBuffer.removeRange(0, _preWakeWordBuffer.length - 17280);
      }
    }
  }

  Future<void> _processRecordedAudio() async {
    if (_sampleBuffer.isEmpty) {
      _stateController.add(AudioState.idle);
      return;
    }
    
    debugPrint('[Audio] Audio ready with ${_sampleBuffer.length} samples');
    final samplesCopy = List<int>.from(_sampleBuffer);
    onAudioReady?.call(samplesCopy);
    
    _sampleBuffer.clear();
    _stateController.add(AudioState.transcribing);

    // Run Sherpa-ONNX Whisper on the buffer
    final transcription = await _asrService.transcribe(samplesCopy);
    if (transcription != null && transcription.isNotEmpty) {
      debugPrint('[ASR] $transcription');
      onTranscription?.call(transcription);
    }

    _stateController.add(AudioState.idle);
  }

  void dispose() {
    _micSub?.cancel();
    _mic.dispose();
    _pipeline?.stop();
    _pipeline?.dispose();
    _asrService.dispose();
    _melController.close();
    _stateController.close();
  }
}
