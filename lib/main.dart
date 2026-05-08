import 'dart:io';
import 'package:flutter/material.dart';
import 'package:buddy_engine/buddy_engine.dart';
import 'services/audio_player_service.dart';
import 'services/onnx_audio_manager.dart';
import 'services/whisper_asr_service.dart';
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
  final WhisperAsrService _whisper = WhisperAsrService();
  OnnxAudioManager? _audioManager;
  bool _whisperReady = false;

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

    // Initialize Whisper ASR
    try {
      await _whisper.initialize(
        encoderPath: '$modelsDir\\whisper\\encoder_model.onnx',
        decoderPath: '$modelsDir\\whisper\\decoder_model.onnx',
        tokenizerPath: '$modelsDir\\whisper\\tokenizer.json',
      );
      _whisperReady = true;
    } catch (e) {
      debugPrint('Whisper init failed: $e');
    }

    _audioManager = OnnxAudioManager();
    _audioManager!.onWakeWord = (word) {
      debugPrint('Wake word: $word');
    };
    _audioManager!.onRecording = (audioSamples) async {
      debugPrint('Recording ready: ${audioSamples.length} samples');
      if (_whisperReady) {
        final text = await _whisper.transcribe(audioSamples);
        if (text != null && text.isNotEmpty) {
          debugPrint('Whisper ASR: $text');
          _agent.enqueue(text);
        }
      }
    };
    _audioManager!.onSpeechStart = () {
      debugPrint('Speech started (VAD)');
    };
    _audioManager!.onSpeechEnd = () {
      debugPrint('Speech ended (VAD)');
    };

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
    _whisper.dispose();
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
