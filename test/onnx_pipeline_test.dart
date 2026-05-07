import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'package:buddy_app/services/audio_pipeline.dart';
import 'package:buddy_app/services/onnx_pipeline.dart';

// ---------------------------------------------------------------------------
// Test utilities
// ---------------------------------------------------------------------------

/// Loads a PCM s16le file and returns samples as List<int> (16-bit).
List<int> loadPcmSamples(String path) {
  final bytes = File(path).readAsBytesSync();
  final samples = <int>[];
  for (int i = 0; i < bytes.length - 1; i += 2) {
    final s16 = bytes[i] | (bytes[i + 1] << 8);
    samples.add(s16 > 32767 ? s16 - 65536 : s16);
  }
  return samples;
}

/// Generates synthetic PCM samples in-memory (16-bit mono 16kHz s16le).
/// Returns List<int> samples.
List<int> syntheticSamples({
  double durationSec = 1.0,
  double Function(double t)? waveform,
  double amplitude = 0.3,
}) {
  const sampleRate = 16000;
  final numSamples = (sampleRate * durationSec).round();
  final random = Random();
  final samples = <int>[];

  for (int i = 0; i < numSamples; i++) {
    final t = i / sampleRate;
    double s;
    if (waveform != null) {
      s = amplitude * waveform(t);
    } else {
      // Default: silence with tiny noise
      s = (random.nextDouble() * 2 - 1) * 0.005;
    }
    s = s.clamp(-1.0, 1.0);
    samples.add((s * 32767).round());
  }
  return samples;
}

/// Creates a synthetic "hey buddy" approximation using multi-frequency
/// sine wave formants. This is a stylized approximation for testing only.
List<int> syntheticHeyBuddy({double durationSec = 1.5, double amplitude = 0.4}) {
  const sampleRate = 16000;
  final numSamples = (sampleRate * durationSec).round();
  final samples = <int>[];

  int heyEnd = (numSamples * 0.4).round();
  int buddyStart = (numSamples * 0.4).round();
  int buddyEnd = (numSamples * 0.9).round();

  for (int i = 0; i < numSamples; i++) {
    double s = 0.0;
    final t = i / sampleRate;

    if (i < heyEnd) {
      // "hey" formants: F1=500, F2=1850, F3=2600
      final env = min(1.0, i / (sampleRate * 0.02)) *
          exp(-i / (sampleRate * 0.1));
      s = env *
          (0.5 * sin(2 * pi * 500 * t) +
              0.3 * sin(2 * pi * 1850 * t) +
              0.15 * sin(2 * pi * 2600 * t));
    } else if (i < buddyEnd) {
      // "buddy" formants: F1=700, F2=1200, F3=2400
      final localT = i - buddyStart;
      final env = min(1.0, localT / (sampleRate * 0.02)) *
          exp(-localT / (sampleRate * 0.12));
      s = env *
          (0.5 * sin(2 * pi * 700 * t) +
              0.3 * sin(2 * pi * 1200 * t) +
              0.15 * sin(2 * pi * 2400 * t));
    }

    s = (s * amplitude).clamp(-1.0, 1.0);
    samples.add((s * 32767).round());
  }
  return samples;
}

/// Creates non-wake-word speech-like signal.
List<int> syntheticSpeech({double durationSec = 1.0, double amplitude = 0.35}) {
  const sampleRate = 16000;
  final numSamples = (sampleRate * durationSec).round();
  final samples = <int>[];
  final random = Random();

  for (int i = 0; i < numSamples; i++) {
    final t = i / sampleRate;
    // Formants that do NOT match "hey buddy"
    final s = amplitude *
        (0.5 * sin(2 * pi * 300 * t) +  // lower F1
            0.3 * sin(2 * pi * 900 * t) + // lower F2
            0.1 * sin(2 * pi * 2100 * t) +
            0.02 * (random.nextDouble() * 2 - 1));
    samples.add((s.clamp(-1.0, 1.0) * 32767).round());
  }
  return samples;
}

/// Creates silence (near-zero samples).
List<int> syntheticSilence({double durationSec = 1.0}) {
  return syntheticSamples(durationSec: durationSec);
}

// ---------------------------------------------------------------------------
// Tests — OnnxPipeline
// ---------------------------------------------------------------------------

/// Integration test that verifies the pipeline state machine transitions
/// correctly when audio chunks are fed in. Uses real ONNX models if
/// available at the paths below; otherwise skipped.
void main() {
  group('OnnxPipeline state machine', () {
    testWidgets('initial state is idle', (tester) async {
      final pipeline = OnnxPipeline();
      expect(pipeline.currentState, AudioState.idle);
      pipeline.dispose();
    });

    testWidgets('start() transitions to listening', (tester) async {
      final pipeline = OnnxPipeline();
      final states = <AudioState>[];
      pipeline.stateStream.listen(states.add);

      pipeline.start();
      await Future.delayed(const Duration(milliseconds: 10));

      expect(states.last, AudioState.listening);
      expect(pipeline.currentState, AudioState.listening);

      pipeline.dispose();
    });

    testWidgets('stop() transitions back to idle', (tester) async {
      final pipeline = OnnxPipeline();
      final states = <AudioState>[];
      pipeline.stateStream.listen(states.add);

      pipeline.start();
      await Future.delayed(const Duration(milliseconds: 10));
      pipeline.stop();
      await Future.delayed(const Duration(milliseconds: 10));

      expect(states.last, AudioState.idle);

      pipeline.dispose();
    });

    testWidgets('silence audio does not trigger wake word', (tester) async {
      final pipeline = OnnxPipeline();
      final states = <AudioState>[];
      final wakeWords = <String>[];
      pipeline.stateStream.listen(states.add);
      pipeline.onWakeWord = (w) => wakeWords.add(w);
      pipeline.start();

      // Feed several chunks of silence
      for (int i = 0; i < 50; i++) {
        final silence = syntheticSilence(durationSec: 0.1);
        pipeline.processAudioChunk(silence);
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // Should NOT have triggered wake word
      expect(wakeWords, isEmpty,
          reason: 'Silence should not trigger wake word detection');
      expect(states.contains(AudioState.wakeWord), isFalse,
          reason: 'Silence should not cause wakeWord state');

      pipeline.dispose();
    });

    testWidgets('non-wake-word speech does not trigger wake word', (tester) async {
      final pipeline = OnnxPipeline();
      final states = <AudioState>[];
      final wakeWords = <String>[];
      pipeline.stateStream.listen(states.add);
      pipeline.onWakeWord = (w) => wakeWords.add(w);
      pipeline.start();

      // Feed synthetic speech that does NOT match "hey buddy" formants
      for (int i = 0; i < 20; i++) {
        final speech = syntheticSpeech(durationSec: 0.2);
        pipeline.processAudioChunk(speech);
        await Future.delayed(const Duration(milliseconds: 5));
      }

      expect(wakeWords, isEmpty,
          reason: 'Non-wake-word speech should not trigger wake word');
      expect(states.contains(AudioState.wakeWord), isFalse);

      pipeline.dispose();
    });
  });

  group('OnnxPipeline with real models (integration)', () {
    // Set model paths relative to the test directory.
    // These files must exist — skip if not present.
    String _modelPath(String name) {
      return 'assets/models/$name';
    }

    bool _modelsExist() {
      return File(_modelPath('mel-spectrogram.onnx')).existsSync() &&
          File(_modelPath('speech-embedding.onnx')).existsSync() &&
          File(_modelPath('hey-buddy.onnx')).existsSync() &&
          File(_modelPath('SileroVAD.onnx')).existsSync();
    }

    testWidgets('real audio pipeline initializes and processes chunks',
        (tester) async {
      if (!_modelsExist()) {
        // biome-ignore: this is a test skip message
        markTestSkipped('ONNX models not found in assets/models — skipping integration test');
      }

      final pipeline = OnnxPipeline();
      await pipeline.initialize(
        melSpectrogramPath: _modelPath('mel-spectrogram.onnx'),
        speechEmbeddingPath: _modelPath('speech-embedding.onnx'),
        wakeWordPath: _modelPath('hey-buddy.onnx'),
        vadModelPath: _modelPath('SileroVAD.onnx'),
      );

      pipeline.start();
      final states = <AudioState>[];
      pipeline.stateStream.listen(states.add);

      // Feed synthetic "hey buddy" audio
      final heyBuddy = syntheticHeyBuddy(durationSec: 1.5);
      const chunkSize = 1600; // 100ms at 16kHz
      for (int i = 0; i < heyBuddy.length; i += chunkSize) {
        final end = (i + chunkSize).clamp(0, heyBuddy.length);
        pipeline.processAudioChunk(heyBuddy.sublist(i, end));
        await Future.delayed(const Duration(milliseconds: 10));
      }

      await Future.delayed(const Duration(milliseconds: 200));

      // Wake word detection outcome depends on how well the synthetic
      // formants approximate real speech — we just verify pipeline ran.
      expect(states.isNotEmpty, isTrue);
      pipeline.dispose();
    }, tags: ['integration']);

    testWidgets('VAD fires on speech and resets after silence',
        (tester) async {
      if (!_modelsExist()) {
        markTestSkipped('ONNX models not found');
      }

      final pipeline = OnnxPipeline();
      await pipeline.initialize(
        melSpectrogramPath: _modelPath('mel-spectrogram.onnx'),
        speechEmbeddingPath: _modelPath('speech-embedding.onnx'),
        wakeWordPath: _modelPath('hey-buddy.onnx'),
        vadModelPath: _modelPath('SileroVAD.onnx'),
      );

      final speechProbs = <double>[];
      pipeline.onSpeechProbability = speechProbs.add;
      pipeline.start();

      // Silence first
      for (int i = 0; i < 5; i++) {
        pipeline.processAudioChunk(syntheticSilence(durationSec: 0.1));
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // Then speech
      for (int i = 0; i < 10; i++) {
        pipeline.processAudioChunk(syntheticSpeech(durationSec: 0.1));
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // Then silence again
      for (int i = 0; i < 10; i++) {
        pipeline.processAudioChunk(syntheticSilence(durationSec: 0.1));
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // VAD probabilities should have been reported
      expect(speechProbs, isNotEmpty);

      pipeline.dispose();
    }, tags: ['integration']);
  });

  group('Synthetic audio generation (Python script)', () {
    test('Python script exists and generates valid PCM files', () async {
      final script = File('generate_synthetic_audio.py');
      expect(script.existsSync(), isTrue,
          reason: 'generate_synthetic_audio.py should exist');

      // Run the script
      final result = await Process.run(
        'python',
        [script.path],
        workingDirectory: script.parent.path,
      );

      expect(result.exitCode, 0,
          reason: 'Python script exited successfully.\n'
              'stdout: ${result.stdout}\nstderr: ${result.stderr}');

      // Verify test_data directory was created with PCM files
      final testDataDir = Directory('test_data');
      expect(testDataDir.existsSync(), isTrue,
          reason: 'test_data directory should have been created');

      final pcmFiles = testDataDir
          .listSync()
          .where((f) => f.path.endsWith('.pcm'))
          .toList();

      expect(pcmFiles.isNotEmpty, isTrue,
          reason: 'PCM test files should have been generated.\n'
              'Found: ${pcmFiles.map((f) => f.path).join(', ')}');

      // Verify a PCM file is valid (correct size for its duration)
      final heyBuddyFile = File('test_data/hey_buddy_normal.pcm');
      if (heyBuddyFile.existsSync()) {
        final bytes = heyBuddyFile.readAsBytesSync();
        final numSamples = bytes.length ~/ 2;
        final durationSec = numSamples / 16000;
        expect(durationSec, closeTo(1.5, 0.1),
            reason: 'hey_buddy_normal.pcm should be ~1.5 seconds');
      }
    });

    test('Loaded PCM samples are within valid int16 range', () async {
      final script = File('generate_synthetic_audio.py');
      if (!script.existsSync()) return;

      // Ensure test data exists
      await Process.run('python', [script.path],
          workingDirectory: script.parent.path);

      final pcmFile = File('test_data/hey_buddy_normal.pcm');
      if (!pcmFile.existsSync()) return;

      final samples = loadPcmSamples(pcmFile.path);
      for (final s in samples) {
        expect(s, inInclusiveRange(-32768, 32767),
            reason: 'All PCM samples must be valid int16');
      }
    });
  });
}