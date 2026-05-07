import 'dart:io';
import 'package:flutter/material.dart';
import 'package:buddy_engine/buddy_engine.dart';
import 'services/audio_player_service.dart';
import 'services/onnx_audio_manager.dart';
import 'services/windows_asr_service.dart';
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
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  final WindowsAsrService _asr = WindowsAsrService();
  OnnxAudioManager? _audioManager;

  @override
  void initState() {
    super.initState();
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
    // Initialize Windows ASR
    _asr.onTranscription = (text) {
      debugPrint('ASR transcription: $text');
      _agent.enqueue(text);
    };
    _asr.onSpeechStart = () {
      debugPrint('ASR started');
    };
    _asr.onSpeechEnd = () {
      debugPrint('ASR ended');
    };
    await _asr.initialize();

    _audioManager = OnnxAudioManager();
    _audioManager!.onWakeWord = (word) async {
      debugPrint('Wake word: $word');
      // Start Windows ASR on wake word
      await _asr.startListening();
    };
    _audioManager!.onRecording = (audioSamples) {
      debugPrint('Recording ready: ${audioSamples.length} samples');
      _audioPlayer.playRecordedClip(audioSamples);
    };
    _audioManager!.onSpeechStart = () {
      debugPrint('Speech started (VAD)');
    };
    _audioManager!.onSpeechEnd = () async {
      debugPrint('Speech ended (VAD)');
      await _asr.stopListening();
    };

    final modelsDir = '${Platform.environment['APPDATA']}\\Buddy\\models';

    try {
      await _audioManager!.initialize(
        melSpectrogramPath: '$modelsDir\\mel-spectrogram.onnx',
        speechEmbeddingPath: '$modelsDir\\speech-embedding.onnx',
        wakeWordPath: '$modelsDir\\hey-buddy.onnx',
        vadModelPath: '$modelsDir\\silero-vad.onnx',
        asrModelPath: '$modelsDir\\encoder.onnx',
        tokensPath: '$modelsDir\\tokens.txt',
      );
      await _audioManager!.start();
    } catch (e) {
      debugPrint('Audio init failed: $e');
    }
  }

  @override
  void dispose() {
    _abortSignal.abort();
    _audioManager?.dispose();
    _asr.dispose();
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
        speechProbabilityStream: _audioManager?.speechProbabilityStream,
      ),
    );
  }
}
