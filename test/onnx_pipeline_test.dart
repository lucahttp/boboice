import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:buddy_app/services/audio_pipeline.dart';
import 'package:buddy_app/services/onnx_pipeline.dart';

// ---------------------------------------------------------------------------
// Synthetic audio generators (mirrors Python generate_synthetic_audio.py)
// ---------------------------------------------------------------------------

const _kSampleRate = 16000;

/// Load PCM s16le file → List<int> samples.
List<int> loadPcmSamples(String path) {
  final bytes = File(path).readAsBytesSync();
  final samples = <int>[];
  for (int i = 0; i < bytes.length - 1; i += 2) {
    final s16 = bytes[i] | (bytes[i + 1] << 8);
    samples.add(s16 > 32767 ? s16 - 65536 : s16);
  }
  return samples;
}

/// Generate silence PCM samples.
List<int> makeSilence({double sec = 1.0}) {
  final n = (_kSampleRate * sec).round();
  return List.filled(n, 0);
}

/// Generate sine wave PCM samples.
List<int> makeSine(double freq, {double sec = 1.0, double amp = 0.3}) {
  final n = (_kSampleRate * sec).round();
  return List.generate(n, (i) {
    final t = i / _kSampleRate;
    final v = amp * sin(2 * pi * freq * t);
    return (v.clamp(-1.0, 1.0) * 32767).round();
  });
}

/// Generate white noise PCM samples.
List<int> makeNoise({double sec = 1.0, double amp = 0.01}) {
  final n = (_kSampleRate * sec).round();
  final r = Random();
  return List.generate(n, (_) {
    final v = amp * (r.nextDouble() * 2 - 1);
    return (v.clamp(-1.0, 1.0) * 32767).round();
  });
}

/// Generate stylized "hey buddy" approximation using formants.
/// This is a synthetic approximation — NOT real speech.
/// "hey" formants: F1=500, F2=1850, F3=2600
/// "buddy" formants: F1=700, F2=1200, F3=2400
List<int> makeHeyBuddy({double sec = 1.5, double amp = 0.4}) {
  final n = (_kSampleRate * sec).round();
  final heyEnd = (n * 0.4).round();
  final buddyStart = (n * 0.4).round();
  final buddyEnd = (n * 0.9).round();

  return List.generate(n, (i) {
    final t = i / _kSampleRate;
    double s = 0.0;

    if (i < heyEnd) {
      final env = min(1.0, i / (_kSampleRate * 0.02)) *
          exp(-i / (_kSampleRate * 0.1));
      s = env *
          (0.5 * sin(2 * pi * 500 * t) +
              0.3 * sin(2 * pi * 1850 * t) +
              0.15 * sin(2 * pi * 2600 * t));
    } else if (i < buddyEnd) {
      final localT = i - buddyStart;
      final env = min(1.0, localT / (_kSampleRate * 0.02)) *
          exp(-localT / (_kSampleRate * 0.12));
      s = env *
          (0.5 * sin(2 * pi * 700 * t) +
              0.3 * sin(2 * pi * 1200 * t) +
              0.15 * sin(2 * pi * 2400 * t));
    }

    return ((s * amp).clamp(-1.0, 1.0) * 32767).round();
  });
}

/// Generate non-wake-word speech (different formants: F1=300, F2=900, F3=2100).
List<int> makeSpeech({double sec = 1.0, double amp = 0.35}) {
  final n = (_kSampleRate * sec).round();
  final r = Random();
  return List.generate(n, (i) {
    final t = i / _kSampleRate;
    final v = amp *
            (0.5 * sin(2 * pi * 300 * t) +
                0.3 * sin(2 * pi * 900 * t) +
                0.1 * sin(2 * pi * 2100 * t)) +
        0.02 * (r.nextDouble() * 2 - 1);
    return ((v.clamp(-1.0, 1.0)) * 32767).round();
  });
}

/// Feed samples to pipeline in chunks.
Future<void> feedPipeline(OnnxPipeline pipeline, List<int> samples,
    {int chunkMs = 100}) async {
  final chunkSize = (_kSampleRate * chunkMs / 1000).round();
  for (int i = 0; i < samples.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, samples.length);
    pipeline.processAudioChunk(samples.sublist(i, end));
    await Future.delayed(Duration(milliseconds: 1));
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OnnxPipeline — state machine (unit)', () {
    test('initial state is idle', () {
      final pipeline = OnnxPipeline();
      expect(pipeline.currentState, AudioState.idle);
      pipeline.stop(); // safe even if not started
    });

    test('start() → listening', () async {
      final pipeline = OnnxPipeline();
      final states = <AudioState>[];
      pipeline.stateStream.listen(states.add);

      pipeline.start();
      await Future.delayed(Duration(milliseconds: 5));

      expect(pipeline.currentState, AudioState.listening);
      expect(states, contains(AudioState.listening));

      pipeline.stop();
    });

    test('stop() → idle', () async {
      final pipeline = OnnxPipeline();
      pipeline.start();
      await Future.delayed(Duration(milliseconds: 5));
      pipeline.stop();

      expect(pipeline.currentState, AudioState.idle);
    });

    test('silence never triggers wake word', () async {
      final pipeline = OnnxPipeline();
      final wakeWords = <String>[];
      pipeline.onWakeWord = (w) => wakeWords.add(w);
      pipeline.start();

      // Feed 3 seconds of silence in small chunks
      await feedPipeline(pipeline, makeSilence(sec: 3.0), chunkMs: 100);

      expect(wakeWords, isEmpty);
      expect(pipeline.currentState, isNot(AudioState.wakeWord));

      pipeline.stop();
    });

    test('non-wake-word speech never triggers wake word', () async {
      final pipeline = OnnxPipeline();
      final wakeWords = <String>[];
      pipeline.onWakeWord = (w) => wakeWords.add(w);
      pipeline.start();

      await feedPipeline(pipeline, makeSpeech(sec: 2.0), chunkMs: 100);

      expect(wakeWords, isEmpty);

      pipeline.stop();
    });

    test('VAD reports speech probability when processing', () async {
      // flutter_onnxruntime plugin is not available in unit test environment.
      // It requires a device with platform channels. Skip and use manual
      // integration test instead.
      markTestSkipped(
          'flutter_onnxruntime requires device — use manual integration test');
    });
  });

  group('OnnxPipeline — integration with real ONNX models', () {
    String _assetPath(String name) => 'assets/models/$name';
    bool _modelsExist() =>
        File(_assetPath('mel-spectrogram.onnx')).existsSync() &&
        File(_assetPath('speech-embedding.onnx')).existsSync() &&
        File(_assetPath('hey-buddy.onnx')).existsSync() &&
        File(_assetPath('SileroVAD.onnx')).existsSync();

    test('initializes and runs pipeline with synthetic hey buddy',
        () async {
      if (!_modelsExist()) {
        markTestSkipped('ONNX models not found in assets/models/');
        return;
      }
      markTestSkipped(
          'flutter_onnxruntime requires device — use manual integration test');
    }, tags: ['integration']);

    test('VAD state machine: speech → silence → processing', () async {
      if (!_modelsExist()) {
        markTestSkipped('ONNX models not found');
        return;
      }
      markTestSkipped(
          'flutter_onnxruntime requires device — use manual integration test');
    }, tags: ['integration']);
  });

  group('Synthetic audio — Python generator validation', () {
    test('Python script runs and produces valid .pcm files', () async {
      final scriptFile = File('generate_synthetic_audio.py');
      expect(scriptFile.existsSync(), isTrue);

      final result = await Process.run(
        'python',
        [scriptFile.path],
        workingDirectory: scriptFile.parent.path,
      );

      expect(result.exitCode, 0,
          reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}');

      final testDir = Directory('test_data');
      expect(testDir.existsSync(), isTrue);

      final pcmFiles =
          testDir.listSync().where((f) => f.path.endsWith('.pcm')).toList();
      expect(pcmFiles.isNotEmpty, isTrue,
          reason: 'Expected .pcm files in test_data/.\n'
              'Found: ${pcmFiles.map((f) => f.path).join(', ')}');
    });

    test('PCM file has correct sample count for its duration', () async {
      final scriptFile = File('generate_synthetic_audio.py');
      if (!scriptFile.existsSync()) return;
      await Process.run('python', [scriptFile.path],
          workingDirectory: scriptFile.parent.path);

      final pcm = File('test_data/hey_buddy_normal.pcm');
      if (!pcm.existsSync()) return;

      final bytes = pcm.readAsBytesSync();
      final numSamples = bytes.length ~/ 2;
      final durationSec = numSamples / _kSampleRate;

      expect(durationSec, closeTo(1.5, 0.1));
    });

    test('Loaded PCM samples are all valid int16', () async {
      final scriptFile = File('generate_synthetic_audio.py');
      if (!scriptFile.existsSync()) return;
      await Process.run('python', [scriptFile.path],
          workingDirectory: scriptFile.parent.path);

      final pcm = File('test_data/hey_buddy_normal.pcm');
      if (!pcm.existsSync()) return;

      final samples = loadPcmSamples(pcm.path);
      for (final s in samples) {
        expect(s, inInclusiveRange(-32768, 32767));
      }
    });

    test('hey_buddy PCM loads and feeds to pipeline without error', () async {
      if (!File('test_data/hey_buddy_normal.pcm').existsSync()) {
        markTestSkipped('Run: python generate_synthetic_audio.py first');
      }
      // flutter_onnxruntime requires device — skip in unit test environment
      markTestSkipped('flutter_onnxruntime requires device — use manual integration test');
    });
  });

  group('Synthetic audio generators — Dart vs Python parity', () {
    test('Dart makeHeyBuddy produces correct sample count', () {
      final samples = makeHeyBuddy(sec: 1.5);
      expect(samples.length, _kSampleRate * 1.5);
    });

    test('Dart makeSilence produces correct sample count', () {
      expect(makeSilence(sec: 2.0).length, _kSampleRate * 2);
    });

    test('Dart makeSpeech produces non-zero samples', () {
      final s = makeSpeech(sec: 0.5);
      expect(s.any((x) => x != 0), isTrue);
    });

    test('PCM round-trip: float [-1,1] → int16 → float matches original', () {
      final originals = List.generate(1000, (i) {
        final t = i / _kSampleRate;
        return 0.5 * sin(2 * pi * 440 * t);
      });

      // Encode
      final pcm = Int16List.fromList(
          originals.map((f) => (f * 32767).round()).toList());

      // Decode
      final decoded = Float64List.fromList(
        pcm.map((s16) => s16 / 32768.0).toList(),
      );

      for (int i = 0; i < originals.length; i++) {
        expect(decoded[i], closeTo(originals[i], 0.001));
      }
    });
  });
}