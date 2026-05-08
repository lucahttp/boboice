import 'dart:math';
import 'dart:typed_data';

/// Pure Dart 80-bin mel spectrogram matching Whisper's feature extractor.
/// Produces output compatible with whisper-tiny.en encoder.
class WhisperMelService {
  static const int sampleRate = 16000;
  static const int nFft = 400; // 25ms window
  static const int hopLength = 160; // 10ms stride
  static const int nMels = 80;
  static const int maxFrames = 3000; // 30s padding

  final Float32List _hannWindow;
  final Float32List _melFilterbank; // [nMels, nFft/2+1]

  WhisperMelService()
      : _hannWindow = _makeHannWindow(nFft),
        _melFilterbank = _makeMelFilterbank(nMels, nFft ~/ 2 + 1, sampleRate);

  /// Compute log-mel spectrogram from raw 16kHz mono float audio.
  /// Returns flat Float32List of shape [nMels * nFrames] ready for ONNX input.
  Float32List computeMel(Float32List audio) {
    // Pad or trim to 30 seconds
    final targetSamples = maxFrames * hopLength + nFft - hopLength;
    final padded = _padOrTrim(audio, targetSamples);

    // STFT
    final numFrames = (padded.length - nFft) ~/ hopLength + 1;
    final nFreq = nFft ~/ 2 + 1;
    final mel = Float32List(nMels * maxFrames);

    for (int t = 0; t < maxFrames; t++) {
      final offset = t * hopLength;
      final magSpec = Float32List(nFreq);

      if (t < numFrames) {
        // Compute magnitude spectrum for this frame
        final real = Float32List(nFft);
        final imag = Float32List(nFft);
        for (int i = 0; i < nFft && (offset + i) < padded.length; i++) {
          real[i] = padded[offset + i] * _hannWindow[i];
        }
        _dft(real, imag);
        for (int i = 0; i < nFreq; i++) {
          magSpec[i] = sqrt(real[i] * real[i] + imag[i] * imag[i]);
        }
      }

      // Apply mel filterbank
      for (int m = 0; m < nMels; m++) {
        double sum = 0;
        for (int k = 0; k < nFreq; k++) {
          sum += _melFilterbank[m * nFreq + k] * magSpec[k];
        }
        mel[m * maxFrames + t] = sum > 1e-10 ? log(sum) : log(1e-10);
      }
    }

    return mel;
  }

  Float32List _padOrTrim(Float32List audio, int targetSamples) {
    if (audio.length >= targetSamples) {
      return Float32List.fromList(audio.sublist(0, targetSamples));
    }
    final padded = Float32List(targetSamples);
    padded.setAll(0, audio);
    return padded;
  }

  void _dft(Float32List real, Float32List imag) {
    final n = real.length;
    final halfN = n ~/ 2;

    // Radix-2 FFT (Cooley-Tukey, decimation in time)
    // Bit-reversal permutation
    int j = 0;
    for (int i = 0; i < n - 1; i++) {
      if (i < j) {
        double tmp = real[i]; real[i] = real[j]; real[j] = tmp;
        tmp = imag[i]; imag[i] = imag[j]; imag[j] = tmp;
      }
      int k = halfN;
      while (k <= j) { j -= k; k ~/= 2; }
      j += k;
    }

    // Butterfly
    for (int len = 2; len <= n; len *= 2) {
      final halfLen = len ~/ 2;
      final angle = -2 * pi / len;
      for (int i = 0; i < n; i += len) {
        for (int k = 0; k < halfLen; k++) {
          final wReal = cos(angle * k);
          final wImag = sin(angle * k);
          final tReal = real[i + k + halfLen] * wReal - imag[i + k + halfLen] * wImag;
          final tImag = real[i + k + halfLen] * wImag + imag[i + k + halfLen] * wReal;
          real[i + k + halfLen] = real[i + k] - tReal;
          imag[i + k + halfLen] = imag[i + k] - tImag;
          real[i + k] += tReal;
          imag[i + k] += tImag;
        }
      }
    }
  }

  static Float32List _makeHannWindow(int size) {
    final w = Float32List(size);
    for (int i = 0; i < size; i++) {
      w[i] = 0.5 * (1 - cos(2 * pi * i / (size - 1)));
    }
    return w;
  }

  /// Create mel filterbank matrix [nMels, nFreq] matching librosa's mel(sr=16000, n_fft=400, n_mels=80).
  static Float32List _makeMelFilterbank(int nMels, int nFreq, int sr) {
    final fMin = 0.0;
    final fMax = sr / 2.0;
    final melMin = _hzToMel(fMin);
    final melMax = _hzToMel(fMax);
    final melPoints = Float32List(nMels + 2);
    for (int i = 0; i < nMels + 2; i++) {
      melPoints[i] = _melToHz(melMin + (melMax - melMin) * i / (nMels + 1));
    }

    final fftFreqs = Float32List(nFreq);
    for (int i = 0; i < nFreq; i++) {
      fftFreqs[i] = sr * i / (2 * (nFreq - 1));
    }

    final fb = Float32List(nMels * nFreq);
    for (int m = 0; m < nMels; m++) {
      for (int k = 0; k < nFreq; k++) {
        final left = melPoints[m];
        final center = melPoints[m + 1];
        final right = melPoints[m + 2];
        final freq = fftFreqs[k];

        double val;
        if (freq >= left && freq <= center) {
          val = (freq - left) / (center - left + 1e-10);
        } else if (freq > center && freq <= right) {
          val = (right - freq) / (right - center + 1e-10);
        } else {
          val = 0;
        }
        fb[m * nFreq + k] = val;
      }
    }
    return fb;
  }

  static double _hzToMel(double hz) => 2595.0 * _log10(1.0 + hz / 700.0);
  static double _melToHz(double mel) => 700.0 * (pow(10.0, mel / 2595.0) - 1.0);
  static double _log10(double x) => log(x) / log(10);
}
