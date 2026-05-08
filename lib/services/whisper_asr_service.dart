import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'whisper_mel_service.dart';
import 'whisper_tokenizer.dart';

/// Whisper ONNX-based speech-to-text service.
/// Uses whisper-tiny.en encoder + decoder ONNX models via flutter_onnxruntime.
class WhisperAsrService {
  final WhisperMelService _mel = WhisperMelService();
  final WhisperTokenizer _tokenizer = WhisperTokenizer();

  OnnxRuntime? _ort;
  OrtSession? _encoderSession;
  OrtSession? _decoderSession;
  bool _initialized = false;

  Future<void> initialize({
    required String encoderPath,
    required String decoderPath,
    required String tokenizerPath,
  }) async {
    if (_initialized) return;

    debugPrint('WhisperASR: loading tokenizer from $tokenizerPath');
    await _tokenizer.load(tokenizerPath);

    _ort = OnnxRuntime();

    debugPrint('WhisperASR: creating encoder session');
    _encoderSession = await _ort!.createSession(encoderPath);

    debugPrint('WhisperASR: creating decoder session');
    _decoderSession = await _ort!.createSession(decoderPath);

    _initialized = true;
    debugPrint('WhisperASR: initialized');
  }

  /// Transcribe audio samples (Float32List, 16kHz mono).
  Future<String?> transcribe(Float32List audioSamples) async {
    if (!_initialized || _encoderSession == null || _decoderSession == null) {
      debugPrint('WhisperASR: not initialized');
      return null;
    }

    try {
      // 1. Compute mel spectrogram [80, 3000]
      debugPrint('WhisperASR: computing mel spectrogram (${audioSamples.length} samples)');
      final mel = _mel.computeMel(audioSamples);

      // 2. Run encoder: input [1, 80, 3000] → output [1, 1500, 384]
      debugPrint('WhisperASR: running encoder');
      final melInput = await OrtValue.fromList(mel, [1, WhisperMelService.nMels, WhisperMelService.maxFrames]);
      final encoderOutputs = await _encoderSession!.run({'input_features': melInput});
      final encoderHidden = encoderOutputs['last_hidden_state'];
      melInput.dispose();
      if (encoderHidden == null) {
        debugPrint('WhisperASR: encoder returned null');
        return null;
      }

      // 3. Decoder loop
      final tokens = await _decodeLoop(encoderHidden);
      encoderHidden.dispose();

      if (tokens.isEmpty) return null;

      // 4. Decode tokens to text
      final text = _tokenizer.decode(tokens);
      debugPrint('WhisperASR: transcription="$text" (${tokens.length} tokens)');
      return text;
    } catch (e) {
      debugPrint('WhisperASR: error $e');
      return null;
    }
  }

  /// Run the decoder autoregressively.
  Future<List<int>> _decodeLoop(OrtValue encoderHidden) async {
    const maxTokens = 100;
    const eot = WhisperTokenizer.eot;
    const vocabSize = 51864;

    // Initial prompt tokens
    final promptTokens = Int64List.fromList(WhisperTokenizer.promptTokens);
    var inputIds = await OrtValue.fromList(promptTokens, [1, promptTokens.length]);

    // First pass with all prompt tokens
    var outputs = await _decoderSession!.run({
      'input_ids': inputIds,
      'encoder_hidden_states': encoderHidden,
    });
    inputIds.dispose();

    var logits = outputs['logits'];
    if (logits == null) return [];
    var flat = await logits.asFlattenedList();
    logits.dispose();

    int nextToken = _argmaxLastToken(flat.cast<num>(), promptTokens.length, vocabSize);
    final result = <int>[];

    for (int i = 0; i < maxTokens; i++) {
      if (nextToken == eot) break;
      result.add(nextToken);

      final nextInput = Int64List.fromList([nextToken]);
      inputIds = await OrtValue.fromList(nextInput, [1, 1]);

      // Always use full forward pass (simpler, fast enough for short audio)
      final nextOutputs = await _decoderSession!.run({
        'input_ids': inputIds,
        'encoder_hidden_states': encoderHidden,
      });
      inputIds.dispose();

      // Dispose old outputs
      for (final v in outputs.values) { try { v.dispose(); } catch (_) {} }

      logits = nextOutputs['logits'];
      if (logits == null) break;
      flat = await logits.asFlattenedList();
      logits.dispose();

      nextToken = _argmaxLastToken(flat.cast<num>(), 1, vocabSize);
      outputs = nextOutputs;
    }

    // Cleanup remaining outputs
    for (final v in outputs.values) { try { v.dispose(); } catch (_) {} }

    return result;
  }

  int _argmaxLastToken(List<num> flat, int seqLen, int vocabSize) {
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

  void dispose() {
    _ort = null;
    _encoderSession = null;
    _decoderSession = null;
    _initialized = false;
  }
}
