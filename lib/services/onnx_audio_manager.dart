import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';
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
  OnlineRecognizer? _recognizer;
  OnlineStream? _stream;
  bool _isRecordingForAsr = false;
  DateTime _lastSpeechTime = DateTime.now();

  final _stateController = StreamController<AudioState>.broadcast();
  AudioState _currentState = AudioState.idle;
  Stream<AudioState> get stateStream => _stateController.stream;

  final _speechProbController = StreamController<double>.broadcast();
  Stream<double> get speechProbabilityStream => _speechProbController.stream;

  /// Called when a wake word fires (wake word detected → recording starts).
  void Function(String wakeWord)? onWakeWord;

  /// Called when speech ends and the recorded clip is ready (Float32List).
  void Function(Float32List audioSamples)? onRecording;

  /// Called every frame: VAD probability (0–1) for visualization.
  void Function(double speechProbability)? onSpeechProbability;

  /// Called when VAD voice activity starts.
  void Function()? onSpeechStart;

  /// Called when VAD voice activity ends (speech ended → triggers onRecording).
  void Function()? onSpeechEnd;

  /// Called with mel spectrogram frames for display.
  void Function(Float32List melFrames)? onMelSpectrogram;

  /// Called when ASR transcription is finalized after silence.
  void Function(String text)? onTranscription;

  /// True while capturing audio after wake word fires.
  bool get isRecording => _recording;
  bool _recording = false;
  Float32List? _recordingBuffer;

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
    bool _lastSpeaking = false;

    _onnxPipeline!.onSpeechProbability = (prob) {
      _speechProbController.add(prob);
      onSpeechProbability?.call(prob);

      // Track speech start/end
      final isSpeaking = prob > 0.5;
      if (isSpeaking && !_lastSpeaking) {
        _lastSpeaking = true;
        onSpeechStart?.call();
      } else if (!isSpeaking && _lastSpeaking) {
        _lastSpeaking = false;
        onSpeechEnd?.call();
        _dispatchRecording();
      }

      // 3s silence ring buffer for ASR
      if (_isRecordingForAsr) {
        if (prob > 0.5) {
          _lastSpeechTime = DateTime.now();
        } else {
          final elapsed = DateTime.now().difference(_lastSpeechTime).inSeconds;
          if (elapsed >= 3) {
            _finalizeAsr();
          }
        }
      }
    };
    _onnxPipeline!.onWakeWord = (word) {
      _setState(AudioState.wakeWord);
      // Reset ASR stream
      _stream?.free();
      _stream = _recognizer!.createStream();
      _isRecordingForAsr = true;
      _lastSpeechTime = DateTime.now();
      _recording = true;
      _recordingBuffer = null;
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

    // Sherpa ASR disabled — ORT API version mismatch (needs 24, have 22).
    // ASR will be handled separately once Sherpa ONNX + ORT version aligned.
    // _recognizer = OnlineRecognizer(...);

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

      // Feed to ASR if recording (Sherpa disabled due to ORT version mismatch)
      if (_isRecordingForAsr && _stream != null && _recognizer != null) {
        final floatSamples = Float32List.fromList(
          samples.map((s) => s / 32768.0).toList(),
        );
        _stream!.acceptWaveform(samples: floatSamples, sampleRate: 16000);
        while (_recognizer!.isReady(_stream!)) {
          _recognizer!.decode(_stream!);
        }
      }

      // Accumulate PCM into recording buffer after wake word fires
      if (_recording) {
        final floatSamples = Float32List.fromList(
          samples.map((s) => s / 32768.0).toList(),
        );
        if (_recordingBuffer == null) {
          _recordingBuffer = floatSamples;
        } else {
          final combined = Float32List(_recordingBuffer!.length + floatSamples.length);
          combined.setAll(0, _recordingBuffer!);
          combined.setAll(_recordingBuffer!.length, floatSamples);
          _recordingBuffer = combined;
        }
      }
    });

    await _mic!.start();
    debugPrint('[AUDIO_MGR] mic started');
    _onnxPipeline?.start();
    debugPrint('[AUDIO_MGR] pipeline started');
    _running = true;
  }

  void _dispatchRecording() {
    if (!_recording || _recordingBuffer == null) return;
    final audio = _recordingBuffer!;
    _recordingBuffer = null;
    _recording = false;
    onRecording?.call(audio);
  }

  void _finalizeAsr() {
    if (_stream == null || _recognizer == null) return;
    _isRecordingForAsr = false;

    if (_recognizer!.isReady(_stream!)) {
      final text = _recognizer!.getResult(_stream!).text.trim();
      if (text.isNotEmpty) {
        onTranscription?.call(text);
      }
    }

    _stream!.free();
    _stream = _recognizer!.createStream();
    _setState(AudioState.idle);
  }

  void stop() {
    _running = false;
    _mic?.stop();
    _onnxPipeline?.stop();
    _dispatchRecording(); // Dispatch any partial recording on stop
  }

  void dispose() {
    stop();
    _mic?.dispose();
    _onnxPipeline?.dispose();
    _stream?.free();
    _recognizer?.free();
    _stateController.close();
    _speechProbController.close();
  }
}