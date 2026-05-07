import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_recorder/flutter_recorder.dart';

/// Real-time microphone capture service using flutter_recorder.
/// Feeds PCM chunks to the audio pipeline for VAD processing.
class MicCaptureService {
  Recorder? _recorder;
  final StreamController<List<int>> _pcmController =
      StreamController<List<int>>.broadcast();
  bool _isCapturing = false;
  int _deviceIndex = -1;

  /// Stream of raw PCM samples (16-bit mono 16kHz s16le).
  Stream<List<int>> get pcmStream => _pcmController.stream;

  bool get isCapturing => _isCapturing;
  int get deviceIndex => _deviceIndex;

  /// List all available input devices.
  Future<List<CaptureDevice>> listDevices() async {
    try {
      return Recorder.instance.listCaptureDevices();
    } catch (e) {
      debugPrint('listDevices failed: $e');
      return [];
    }
  }

  /// Initialize with a specific device index (-1 for default).
  /// Sets up the PCM stream listener ONCE here, not in start().
  Future<void> init({int deviceIndex = -1, int sampleRate = 16000}) async {
    await deinit();
    try {
      await Recorder.instance.init(
        deviceID: deviceIndex,
        format: PCMFormat.s16le,
        sampleRate: sampleRate,
        channels: RecorderChannels.mono,
      );
      _deviceIndex = deviceIndex;

      // Listen to PCM stream once during init. Data flows after startStreamingData().
      // This must be set up BEFORE startStreamingData() is called.
      Recorder.instance.uint8ListStream.listen((data) {
        final samples = <int>[];
        final buf = data.rawData;
        for (int i = 0; i < buf.length - 1; i += 2) {
          final sample = buf[i] | (buf[i + 1] << 8);
          samples.add(sample > 32767 ? sample - 65536 : sample);
        }
        if (samples.isNotEmpty) {
          _pcmController.add(samples);
        }
      });
    } catch (e) {
      debugPrint('MicCapture init failed: $e');
      rethrow;
    }
  }

  /// Start capturing audio. Stream listener already set up in init().
  Future<void> start() async {
    if (_isCapturing) return;
    try {
      Recorder.instance.start();
      Recorder.instance.startStreamingData();
      _isCapturing = true;
    } catch (e) {
      debugPrint('MicCapture start failed: $e');
      _isCapturing = false;
      rethrow;
    }
  }

  /// Stop capturing audio.
  Future<void> stop() async {
    if (!_isCapturing) return;
    try {
      Recorder.instance.stopStreamingData();
      Recorder.instance.stop();
    } catch (e) {
      debugPrint('MicCapture stop failed: $e');
    } finally {
      _isCapturing = false;
    }
  }

  /// Deinitialize the recorder.
  Future<void> deinit() async {
    await stop();
    try {
      Recorder.instance.deinit();
    } catch (e) {
      debugPrint('MicCapture deinit: $e');
    }
    _deviceIndex = -1;
  }

  void dispose() {
    deinit();
    _pcmController.close();
  }
}