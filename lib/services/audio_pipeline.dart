import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

/// Audio pipeline state for UI display.
enum AudioState {
  idle,
  listening,
  wakeWord,
  processing,
  speaking,
}

/// Speech probability stream for real-time audio visualization.
/// Emits values 0.0–1.0 from VAD for each processed chunk.
final _speechProbController = StreamController<double>.broadcast();
Stream<double> get speechProbabilityStream => _speechProbController.stream;

/// Audio pipeline — sherpa_onnx for VAD, wake word, ASR, TTS.
///
/// Pipeline stages (mirrors hey-buddy architecture):
///   1. Raw audio → chunk at batchInterval (caller-managed)
///   2. Chunks → SileroVAD (VoiceActivityDetector)
///   3. Speech detected → KeywordSpotter (wake word) + OnlineRecognizer (ASR)
///
/// Wake word model: benjamin-paine/hey-buddy onnx (custom "hey buddy" phrase)
/// VAD model: SileroVAD (sherpa-onnx built-in)
/// ASR model: Whisper/SenseVoice (sherpa-onnx)
/// TTS model: VITS (sherpa-onnx)
///
/// Reference: https://github.com/painebenjamin/hey-buddy/tree/main/src
class AudioPipeline {
  bool _isListening = false;
  bool _isSpeaking = false;

  VoiceActivityDetector? _vad;
  KeywordSpotter? _spotter;
  OnlineRecognizer? _recognizer;
  OfflineTts? _tts;
  AudioPlayer? _audioPlayer;

  bool get isListening => _isListening;
  bool get isSpeaking => _isSpeaking;

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

  /// Called with transcribed text
  void Function(String text)? onTranscription;

  /// Called with detected wake word phrase
  void Function(String wakeWord)? onWakeWord;

  /// Called when VAD detects speech / silence
  void Function(bool isSpeaking)? onVadState;

  /// Initialize with model file paths.
  ///
  /// [wakeWordModel] — path to hey-buddy ONNX (transducer .onnx with encoder/decoder/joiner)
  /// [vadModel] — path to SileroVAD .onnx
  /// [asrModel] — base path for ASR transducer: expects encoder.onnx, decoder.onnx, joiner.onnx
  ///   (If asrModel ends with .onnx, derives encoder/decoder/joiner from parent dir + same stem)
  /// [tokensPath] — path to tokens.txt for ASR decoding
  /// [ttsModel] — optional VITS .onnx
  Future<void> initialize({
    required String wakeWordModel,
    required String vadModel,
    required String asrModel,
    String? tokensPath,
    String? ttsModel,
  }) async {
    initBindings();

    // ── Wake word (KeywordSpotter) — DISABLED ─────────────────────────
    // hey-buddy.onnx lacks icefall metadata (model_type, tokens table).
    // KeywordSpotter requires icefall-exported transducer models.
    // For now: VAD only (no wake word detection).

    // ── VAD (VoiceActivityDetector with SileroVAD) ─────────────────────
    _vad = VoiceActivityDetector(
      config: VadModelConfig(
        sileroVad: SileroVadModelConfig(model: vadModel),
        sampleRate: 16000,
        numThreads: 1,
      ),
      bufferSizeInSeconds: 30,
    );

    // ── ASR (OnlineRecognizer with transducer) ─────────────────────────
    // asrModel is the base dir; we look for encoder.onnx, decoder.onnx, joiner.onnx
    // tokensPath defaults to <asrModel>/../tokens.txt
    String actualTokensPath = tokensPath ?? asrModel;
    String parentDir;
    if (asrModel.endsWith('.onnx')) {
      parentDir = File(asrModel).parent.path;
      if (tokensPath == null) {
        actualTokensPath = '$parentDir${Platform.pathSeparator}tokens.txt';
      }
    } else {
      parentDir = asrModel;
    }
    final encoderPath = '$parentDir${Platform.pathSeparator}encoder.onnx';
    final decoderPath = '$parentDir${Platform.pathSeparator}decoder.onnx';
    final joinerPath = '$parentDir${Platform.pathSeparator}joiner.onnx';
    _recognizer = OnlineRecognizer(OnlineRecognizerConfig(
      model: OnlineModelConfig(
        transducer: OnlineTransducerModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
          joiner: joinerPath,
        ),
        tokens: actualTokensPath,
        numThreads: 1,
        debug: kDebugMode,
      ),
      feat: const FeatureConfig(sampleRate: 16000),
    ));

    // ── TTS (OfflineTts with VITS) — optional, skip if model missing ───
    if (ttsModel != null) {
      if (File(ttsModel).existsSync()) {
        _tts = OfflineTts(OfflineTtsConfig(
          model: OfflineTtsModelConfig(vits: OfflineTtsVitsModelConfig(model: ttsModel)),
        ));
      } else {
        debugPrint('TTS model not found: $ttsModel — skipping TTS');
      }
    }
  }

  void start() {
    _isListening = true;
    _setState(AudioState.listening);
  }

  void stop() {
    _isListening = false;
    _setState(AudioState.idle);
  }

  /// Real-time speech probability stream (0.0–1.0) for visualization.
  /// Driven by RMS energy of each processed audio chunk.
  Stream<double> get speechStream => _speechProbController.stream;

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

    // Normalize to float32 [-1, 1]
    final floatSamples = Float32List.fromList(
      samples.map((s) => s / 32768.0).toList(),
    );

    // ── VAD ─────────────────────────────────────────────────────────────
    if (_vad != null) {
      _vad!.acceptWaveform(floatSamples);
      while (!_vad!.isEmpty()) {
        final segment = _vad!.front();
        onVadState?.call(true);
        _vad!.pop();
        final samples = segment.samples;
        _processSpeechSegment(samples);
      }
    }
  }

  void _processSpeechSegment(Float32List samples) {
    // ── Wake word (TEMPORARILY DISABLED) ───────────────────────────────
    // Skipping _spotter checks until we have a proper icefall transducer model.
    // For now: VAD → ASR only (no wake word detection).

    // ── ASR ─────────────────────────────────────────────────────────────
    if (_recognizer != null && samples.isNotEmpty) {
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _recognizer!.decode(stream);
      _setState(AudioState.processing);
      if (_recognizer!.isReady(stream)) {
        final text = _recognizer!.getResult(stream).text;
        if (text.isNotEmpty) {
          onTranscription?.call(text);
        }
      }
    }
  }

  void speak(String text) {
    if (_tts == null) return;
    _setState(AudioState.speaking);
    _isSpeaking = true;

    try {
      final audio = _tts!.generate(text: text);
      final pcmData = audio.samples;
      final sampleRate = audio.sampleRate;

      // Convert Float32List PCM to 16-bit PCM bytes
      final pcmBytes = Uint8List(pcmData.length * 2);
      for (int i = 0; i < pcmData.length; i++) {
        final sample = (pcmData[i] * 32767).clamp(-32768.0, 32767.0).toInt();
        pcmBytes[i * 2] = sample & 0xFF;
        pcmBytes[i * 2 + 1] = (sample >> 8) & 0xFF;
      }

      // Create a memory audio source from the PCM bytes
      final audioSource = _MyPcmAudioSource(pcmBytes, sampleRate);

      _audioPlayer ??= AudioPlayer();
      _audioPlayer!.playbackEventStream.listen((event) {
        if (event.processingState == ProcessingState.completed) {
          _isSpeaking = false;
          _setState(AudioState.idle);
        }
      });
      _audioPlayer!.setAudioSource(audioSource);
      _audioPlayer!.play();
    } catch (e) {
      debugPrint('TTS error: $e');
      _isSpeaking = false;
      _setState(AudioState.idle);
    }
  }

  void dispose() {
    stop();
    _spotter?.free();
    _vad?.free();
    _recognizer?.free();
    _tts?.free();
    _audioPlayer?.dispose();
    _stateController.close();
  }
}

/// Stream audio source that plays raw PCM s16le data.
class _MyPcmAudioSource extends StreamAudioSource {
  final Uint8List _pcmBytes;
  final int _sampleRate;

  _MyPcmAudioSource(this._pcmBytes, this._sampleRate);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _pcmBytes.length;
    return StreamAudioResponse(
      sourceLength: _pcmBytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_pcmBytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}