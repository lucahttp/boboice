import 'dart:async';
import 'audio_pipeline.dart';
import 'mic_capture_service.dart';

/// Manages the audio pipeline on the main isolate.
///
/// The isolate pattern was attempted but _audioIsolateEntry was empty.
/// For now the pipeline runs on the main thread, which is fine for small
/// ONNX models on Windows. Can be moved to a proper isolate later.
class AudioIsolateManager {
  bool _running = false;
  AudioPipeline? _pipeline;

  void Function(String wakeWord)? onWakeWord;
  void Function(String text)? onTranscription;
  void Function(bool isSpeaking)? onVadState;
  void Function(AudioState state)? onAudioState;

  bool get isRunning => _running;

  /// Process a raw audio chunk through the pipeline (from mic capture).
  void processAudioChunk(List<int> samples) {
    _pipeline?.processAudioChunk(samples);
  }

  /// Start capturing from a mic service and feed chunks to the pipeline.
  Future<void> startCapture(MicCaptureService mic) async {
    if (_pipeline == null) throw StateError('Call initialize() first');
    await mic.start();
    mic.pcmStream.listen((samples) => processAudioChunk(samples));
  }

  Future<void> initialize({
    required String wakeWordModel,
    required String vadModel,
    required String asrModel,
    String? tokensPath,
    String? ttsModel,
  }) async {
    _pipeline ??= AudioPipeline();
    await _pipeline!.initialize(
      wakeWordModel: wakeWordModel,
      vadModel: vadModel,
      asrModel: asrModel,
      tokensPath: tokensPath,
      ttsModel: ttsModel,
    );
  }

  Stream<AudioState> get stateStream {
    if (_pipeline == null) return const Stream.empty();
    return _pipeline!.stateStream;
  }

  /// Real-time speech probability stream (0.0–1.0) for audio visualization.
  Stream<double> get speechProbabilityStream => _pipeline?.speechStream ?? const Stream.empty();

  Future<void> start() async {
    if (_running) return;
    if (_pipeline == null) throw StateError('Call initialize() first');

    _pipeline!.onWakeWord = (word) => onWakeWord?.call(word);
    _pipeline!.onTranscription = (text) => onTranscription?.call(text);
    _pipeline!.onVadState = (speaking) => onVadState?.call(speaking);
    _pipeline!.stateStream.listen((state) => onAudioState?.call(state));

    _pipeline!.start();
    _running = true;
  }

  void stop() {
    _pipeline?.stop();
    _running = false;
  }

  Future<void> speak(String text) async => _pipeline?.speak(text);

  void dispose() {
    stop();
    _pipeline?.dispose();
    _pipeline = null;
  }
}
