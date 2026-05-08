import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Windows-native speech recognition via speech_to_text package.
/// Uses Windows Speech API (Cortana-level recognition, works offline).
class WindowsAsrService {
  final SpeechToText _stt = SpeechToText();
  bool _isListening = false;
  bool _isInitialized = false;

  WindowsAsrService() {
    debugPrint('WindowsAsrService created');
  }

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
    debugPrint('STT initialize called');
    _isInitialized = true;
    final success = await _stt.initialize(
      onStatus: (status) {
        debugPrint('STT status: $status');
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
    debugPrint('STT initialize done, success=$success');
  }

  /// Start listening for speech. Calls onTranscription for each recognized phrase.
  Future<void> startListening() async {
    if (!_isInitialized) {
      debugPrint('STT startListening: not initialized, calling initialize');
      await initialize();
    }
    if (_isListening) {
      debugPrint('STT startListening: already listening');
      return;
    }

    debugPrint('STT startListening called');
    _isListening = true;
    onSpeechStart?.call();

    try {
      await _stt.listen(
        onResult: (result) {
          try {
            debugPrint('STT result: final=${result.finalResult} words="${result.recognizedWords}"');
            // Guard against null recognizedWords (seen in some Windows plugin versions)
            final words = result.recognizedWords;
            if (words == null || words.isEmpty) return;
            if (result.finalResult) {
              final text = words.trim();
              if (text.isNotEmpty) {
                debugPrint('STT transcription: $text');
                onTranscription?.call(text);
              }
            }
          } catch (e) {
            debugPrint('STT onResult error: $e');
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        partialResults: false,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
      );
      debugPrint('STT listen call returned');
    } catch (e) {
      debugPrint('STT listen exception: $e');
      _isListening = false;
      onSpeechEnd?.call();
    }
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