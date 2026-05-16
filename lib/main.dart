import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:buddy_engine/buddy_engine.dart';
import 'services/audio_player_service.dart';
import 'services/buddy_audio_manager.dart';
import 'ui/conversation_screen.dart';

void main() { runApp(const BuddyApp()); }

class BuddyApp extends StatefulWidget {
  const BuddyApp({super.key});
  @override
  State<BuddyApp> createState() => _BuddyAppState();
}

class _BuddyAppState extends State<BuddyApp> {
  late final VoiceAgent _agent;
  final Personality _personality = Personality();
  final ToolRegistry _toolRegistry = ToolRegistry();
  late final AbortSignal _abortSignal;
  late final AudioPlayerService _audioPlayer;
  BuddyAudioManager? _audioManager;
  final _recordingsController = StreamController<String>.broadcast();

  AudioPlayerService _makeAudioPlayer() {
    try {
      return AudioPlayerService();
    } catch (_) {
      return NoopAudioPlayer();
    }
  }

  @override
  void initState() {
    super.initState();
    _audioPlayer = _makeAudioPlayer();
    _abortSignal = AbortSignal();

    // MiniMax LLM via OpenAI-compatible API
    final llm = OpenAiProvider(
      baseUrl: 'https://api.minimax.io/v1',
      apiKey: const String.fromEnvironment('MINIMAX_API_KEY',
          defaultValue: 'sk-cp-0KeOTVpfnoMGdXs6TYanRVzCRY7QYAmk5a9cnlVr-rJ8XrMcp_pfm8JALYjmv36xOlH6E_P6j75pU3Yir-Tgy8XdxMcAkn54otDbG-glS3OPwgh4ZHc0y_M'),
      defaultModel: 'MiniMax-M2',
    );

    _toolRegistry.registerAll(createBuiltinTools(
      onSetPersonality: (dial, value) => setState(() => _personality.set(dial, value)),
      availableSkills: const [],
    ));

    _agent = VoiceAgent(
      llm: llm,
      toolRegistry: _toolRegistry,
      personality: _personality,
      abortSignal: _abortSignal,
    );
    _agent.initialize();
    _initAudio();
  }

  Future<void> _initAudio() async {
    final modelsDir = '${Platform.environment['APPDATA']}\\Buddy\\models';

    _audioManager = BuddyAudioManager();
    
    _audioManager!.onWakeWord = (word) {
      debugPrint('Wake word: $word');
    };

    _audioManager!.onTranscription = (text) async {
      debugPrint('Whisper ASR: $text');
      _agent.enqueue(text);
    };

    _audioManager!.onAudioReady = (samples) async {
      final outPath = '${Directory.current.path}\\recording_${DateTime.now().millisecondsSinceEpoch}.wav';
      debugPrint('Audio recorded: ${samples.length} samples. Saving to $outPath...');
      await _audioPlayer.savePcmToWav(samples, outPath);
      debugPrint('Saved successfully. Sending to UI...');
      _recordingsController.add(outPath);
    };

    _audioManager!.onAudioCaptured = (samples) {
      // Optional: Real-time playback without latency can be hooked here
    };

    try {
      await _audioManager!.initialize(
        wakeWordPath: '$modelsDir\\hey-buddy.onnx',
        asrTokensPath: '$modelsDir\\tokens.txt',
        asrEncoderPath: '$modelsDir\\whisper\\encoder_model.onnx',
        asrDecoderPath: '$modelsDir\\whisper\\decoder_model.onnx',
        asrJoinerPath: '$modelsDir\\joiner.onnx',
        melSpectrogramPath: '$modelsDir\\mel-spectrogram.onnx',
        speechEmbeddingPath: '$modelsDir\\speech-embedding.onnx',
        vadModelPath: '$modelsDir\\silero-vad.onnx',
      );
      await _audioManager!.start();
      debugPrint('BuddyAudioManager started with ONNX pipeline');
    } catch (e) {
      debugPrint('Audio init failed: $e');
    }
  }

  @override
  void dispose() {
    _abortSignal.abort();
    _recordingsController.close();
    _audioManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Buddy',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.cyan, brightness: Brightness.dark),
      ),
      home: ConversationScreen(
        agent: _agent,
        personality: _personality,
        audioStateStream: _audioManager?.stateStream,
        speechProbabilityStream: null,
        melSpectrogramStream: _audioManager?.melSpectrogramStream,
        recordedAudioStream: _recordingsController.stream,
      ),
    );
  }
}
