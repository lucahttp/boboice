import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Windows-native speech recognition via speech_to_text package.
/// Uses Windows Speech API (Cortana-level recognition, works offline).
class WindowsAsrService {
  final SpeechToText _stt = SpeechToText();
  bool _isListening = false;
  bool _isInitialized = false;

  /// Called with transcribed text
  void Function(String text)? onTranscription;

  /// Called on speech start
  void Function()? onSpeechStart;

  /// Called on speech end
  void Function()? onSpeechEnd;

  bool get isListening => _isListening;

  /// Initialize Windows speech recognition.
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    await _stt.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (_isListening) {
            _isListening = false;
            onSpeechEnd?.call();
          }
        }
      },
      onError: (error) {
        debugPrint('STT error: $error');
        _isListening = false;
        onSpeechEnd?.call();
      },
    );
  }

  /// Start listening for speech. Calls onTranscription for each recognized phrase.
  Future<void> startListening() async {
    if (!_isInitialized) await initialize();
    if (_isListening) return;

    debugPrint('STT startListening called');
    _isListening = true;
    onSpeechStart?.call();

    await _stt.listen(
      onResult: (result) {
        debugPrint('STT result: final=${result.finalResult} words="${result.recognizedWords}"');
        if (result.finalResult) {
          final text = result.recognizedWords.trim();
          if (text.isNotEmpty) {
            debugPrint('STT transcription: $text');
            onTranscription?.call(text);
          }
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      partialResults: false,
      cancelOnError: false,
      listenMode: ListenMode.dictation,
    );
  }

  /// Stop listening.
  Future<void> stopListening() async {
    if (!_isListening) return;
    await _stt.stop();
    _isListening = false;
  }

  void dispose() {
    _stt.stop();
    _isListening = false;
  }
}