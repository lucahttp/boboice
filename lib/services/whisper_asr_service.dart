import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'whisper_mel_service.dart';
import 'whisper_tokenizer.dart';

/// Configuration for compute isolate transcription.
class WhisperTranscribeConfig {
  final Float32List audioSamples;
  final String encoderPath;
  final String decoderPath;
  final String tokenizerPath;
  WhisperTranscribeConfig({
    required this.audioSamples,
    required this.encoderPath,
    required this.decoderPath,
    required this.tokenizerPath,
  });
}

/// Result from transcription.
class WhisperTranscribeResult {
  final String? text;
  final String? error;
  WhisperTranscribeResult({this.text, this.error});
}

/// Runs transcription in an isolate using compute().
Future<WhisperTranscribeResult> _transcribeInIsolate(WhisperTranscribeConfig config) async {
  try {
    // Initialize ONNX in this isolate
    final ort = OnnxRuntime();
    final encoderSession = await ort.createSession(config.encoderPath);
    final decoderSession = await ort.createSession(config.decoderPath);

    // Load tokenizer
    final tokenizer = WhisperTokenizer();
    await tokenizer.load(config.tokenizerPath);

    // Mel service
    final melService = WhisperMelService();

    // 1. Compute mel spectrogram
    final mel = melService.computeMel(config.audioSamples);

    // 2. Run encoder
    final melInput = await OrtValue.fromList(mel, [1, WhisperMelService.nMels, WhisperMelService.maxFrames]);
    final encoderOutputs = await encoderSession.run({'input_features': melInput});
    final encoderHidden = encoderOutputs['last_hidden_state'];
    melInput.dispose();
    if (encoderHidden == null) {
      return WhisperTranscribeResult(error: 'Encoder returned null');
    }

    // 3. Decoder loop
    final tokens = await _decodeLoopStatic(decoderSession, encoderHidden);

    if (tokens.isEmpty) {
      return WhisperTranscribeResult(error: 'No tokens');
    }

    // 4. Decode tokens
    final text = tokenizer.decode(tokens);
    return WhisperTranscribeResult(text: text);
  } catch (e) {
    return WhisperTranscribeResult(error: 'Transcription error: $e');
  }
}

/// Static decoder loop to run inside the isolate.
Future<List<int>> _decodeLoopStatic(OrtSession session, OrtValue encoderHidden) async {
  const maxTokens = 100;
  const eot = 50256;
  const vocabSize = 51864;

  final promptTokens = [50257, 50364, 50363, 50476, 50643, 50365, 50476, 50619, 50363, 50505, 50359, 50476, 50619, 50505, 50359, 50476, 50619, 50363, 50476, 50619, 50363, 50476, 50619, 50363, 50476, 50619, 50363, 50362, 50363, 50476];
  var inputIds = await OrtValue.fromList(Int64List.fromList(promptTokens), [1, promptTokens.length]);

  var outputs = await session.run({
    'input_ids': inputIds,
    'encoder_hidden_states': encoderHidden,
  });
  inputIds.dispose();

  var logits = outputs['logits'];
  if (logits == null) return [];
  var flat = await logits.asFlattenedList();
  logits.dispose();

  int nextToken = _argmaxLastTokenStatic(flat.cast<num>(), promptTokens.length, vocabSize);
  final result = <int>[];

  for (int i = 0; i < maxTokens; i++) {
    if (nextToken == eot) break;
    result.add(nextToken);

    final nextInput = Int64List.fromList([nextToken]);
    inputIds = await OrtValue.fromList(nextInput, [1, 1]);

    final nextOutputs = await session.run({
      'input_ids': inputIds,
      'encoder_hidden_states': encoderHidden,
    });
    inputIds.dispose();

    for (final v in outputs.values) { try { v.dispose(); } catch (_) {} }

    logits = nextOutputs['logits'];
    if (logits == null) break;
    flat = await logits.asFlattenedList();
    logits.dispose();

    nextToken = _argmaxLastTokenStatic(flat.cast<num>(), 1, vocabSize);
    outputs = nextOutputs;
  }

  for (final v in outputs.values) { try { v.dispose(); } catch (_) {} }

  return result;
}

int _argmaxLastTokenStatic(List<num> flat, int seqLen, int vocabSize) {
  final offset = (seqLen - 1) * vocabSize;
  int maxIdx = 0;
  double maxVal = flat[offset].toDouble();
  for (int i = 1; i < vocabSize; i++) {
    final val = flat[offset + i].toDouble();
    if (val > maxVal) {
      maxVal = val;
      maxIdx = i;
    }
  }
  return maxIdx;
}

/// Whisper ASR service using compute() for background transcription.
class WhisperAsrService {
  /// Transcribe audio samples (Float32List, 16kHz mono).
  /// Runs ONNX inference directly on this isolate (not the main thread).
  /// Note: flutter_onnxruntime runs inference on a native thread pool,
  /// so this doesn't block the Dart event loop.
  Future<String?> transcribe(Float32List audioSamples) async {
    final config = WhisperTranscribeConfig(
      audioSamples: audioSamples,
      encoderPath: _encoderPath!,
      decoderPath: _decoderPath!,
      tokenizerPath: _tokenizerPath!,
    );

    // Run inference directly (not via compute()).
    // flutter_onnxruntime executes ONNX ops on native thread pool,
    // so Dart async operations (await) yield to the event loop.
    final result = await _transcribeInIsolate(config);

    if (result.error != null) {
      print('WhisperASR: ${result.error}');
      return null;
    }
    return result.text;
  }

  // Stored paths for re-use in compute
  String? _encoderPath;
  String? _decoderPath;
  String? _tokenizerPath;

  bool _initialized = false;
  bool get isReady => _initialized;

  Future<void> initialize({
    required String encoderPath,
    required String decoderPath,
    required String tokenizerPath,
  }) async {
    if (_initialized) return;

    _encoderPath = encoderPath;
    _decoderPath = decoderPath;
    _tokenizerPath = tokenizerPath;

    _initialized = true;
    print('WhisperASR: initialized');
  }

  void dispose() {
    _initialized = false;
  }
}
