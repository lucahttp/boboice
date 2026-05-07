import 'dart:typed_data';
import 'package:just_audio/just_audio.dart';

/// Plays back a recorded audio clip (Float32List, 16kHz mono PCM).
/// Converts to PCM WAV data and feeds to just_audio player.
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;

  bool get isPlaying => _isPlaying;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  /// Load and play a Float32List audio buffer (16kHz mono).
  Future<void> playRecordedClip(Float32List samples, {int sampleRate = 16000}) async {
    try {
      await stop();

      // Convert Float32List [-1,1] to WAV bytes
      final wavBytes = _float32ToWav(samples, sampleRate: sampleRate);

      // Feed WAV bytes to just_audio via a custom stream source
      final source = _WavStreamSource(wavBytes);

      await _player.setAudioSource(source);
      _player.playerStateStream.listen((state) {
        _isPlaying = state.playing;
      });
      await _player.play();
    } catch (e) {
      _isPlaying = false;
    }
  }

  Future<void> stop() async {
    await _player.stop();
    _isPlaying = false;
  }

  void dispose() {
    _player.dispose();
  }

  /// Convert Float32List [-1,1] to 16-bit PCM WAV byte list.
  Uint8List _float32ToWav(Float32List samples, {int sampleRate = 16000}) {
    final numChannels = 1;
    final bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataSize = samples.length * numChannels * bitsPerSample ~/ 8;
    final fileSize = 36 + dataSize;

    final buf = ByteData(44 + dataSize);
    int o = 0;

    // RIFF header
    buf.setUint32(o, 0x52494646); o += 4; // "RIFF"
    buf.setUint32(o, fileSize); o += 4;
    buf.setUint32(o, 0x57415645); o += 4; // "WAVE"

    // fmt subchunk
    buf.setUint32(o, 0x666D7420); o += 4; // "fmt "
    buf.setUint32(o, 16); o += 4;          // subchunk1 size (PCM)
    buf.setUint16(o, 1); o += 2;           // audio format (PCM)
    buf.setUint16(o, numChannels); o += 2;
    buf.setUint32(o, sampleRate); o += 4;
    buf.setUint32(o, byteRate); o += 4;
    buf.setUint16(o, blockAlign); o += 2;
    buf.setUint16(o, bitsPerSample); o += 2;

    // data subchunk
    buf.setUint32(o, 0x64617461); o += 4; // "data"
    buf.setUint32(o, dataSize); o += 4;

    // PCM samples
    for (int i = 0; i < samples.length; i++) {
      final s = samples[i].clamp(-1.0, 1.0);
      final pcm = (s < 0 ? s * 0x8000 : s * 0x7FFF).toInt();
      buf.setInt16(o, pcm, Endian.little); o += 2;
    }

    return buf.buffer.asUint8List();
  }
}

/// StreamAudioSource that returns raw WAV bytes.
class _WavStreamSource extends StreamAudioSource {
  final Uint8List _wavBytes;

  _WavStreamSource(this._wavBytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _wavBytes.length;
    return StreamAudioResponse(
      sourceLength: _wavBytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_wavBytes.sublist(start, end)),
      contentType: 'audio/wav',
    );
  }
}
