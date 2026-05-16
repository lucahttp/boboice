import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:buddy_engine/buddy_engine.dart';
import '../services/audio_device_service.dart';
import '../services/audio_pipeline.dart';
import '../services/audio_player_service.dart';
import 'audio_settings_sheet.dart';
import 'widgets/voice_activity_indicator.dart' show VoiceActivityIndicator;
import 'widgets/live_waveform.dart' show LiveWaveform;
import 'widgets/mel_spectrogram_visualizer.dart' show MelSpectrogramVisualizer;

/// Main conversation screen with chat messages, status streaming, and input.
class ConversationScreen extends StatefulWidget {
  final VoiceAgent agent;
  final Personality personality;
  final Stream<AudioState>? audioStateStream;
  final Stream<double>? speechProbabilityStream;
  final Stream<Float32List>? melSpectrogramStream;

  const ConversationScreen({
    super.key,
    required this.agent,
    required this.personality,
    this.audioStateStream,
    this.speechProbabilityStream,
    this.melSpectrogramStream,
  });

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  late final AudioPlayerService _audioPlayer;
  bool _isProcessing = false;

  final AudioDeviceService _deviceService = AudioDeviceService();
  AudioState _audioState = AudioState.idle;
  StreamSubscription? _audioStateSub;

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
    _messages.add(_ChatMessage(
      role: 'assistant',
      text: 'Hey buddy! What can I help you with?',
    ));
    _audioStateSub = widget.audioStateStream?.listen((state) {
      if (mounted) setState(() => _audioState = state);
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _audioStateSub?.cancel();
    super.dispose();
  }

  Future<void> _showAudioSettings() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: AudioSettingsSheet(
          deviceService: _deviceService,
          voiceState: _audioState,
        ),
      ),
    );
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty || _isProcessing) return;

    setState(() {
      _messages.add(_ChatMessage(role: 'user', text: text.trim()));
      _isProcessing = true;
    });
    _inputController.clear();

    final events = widget.agent.process(text.trim());
    StringBuffer response = StringBuffer();

    await for (final event in events) {
      if (!mounted) break;

      switch (event) {
        case ReasoningDeltaEvent(:final delta):
          setState(() {
            _messages.add(_ChatMessage(role: 'reasoning', text: delta));
          });

        case TextDeltaEvent(:final delta):
          response.write(delta);
          setState(() {
            if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
              _messages.last = _ChatMessage(role: 'assistant', text: response.toString(), isStreaming: true);
            } else {
              _messages.add(_ChatMessage(role: 'assistant', text: response.toString(), isStreaming: true));
            }
          });

        case TextEndEvent(:final id): {
          // id is unused but must be matched to satisfy sealed class exhaustiveness
          final _ = id;
        }
          setState(() {
            if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
              _messages.last = _ChatMessage(role: 'assistant', text: response.toString(), isStreaming: false);
            }
          });

        case ToolCallEvent(:final callId, :final name, :final arguments): {
          // callId is unused but must be matched to satisfy sealed class exhaustiveness
          final _ = callId;
        }
          setState(() {
            _messages.add(_ChatMessage(
              role: 'tool_call',
              text: '🔧 $name(${arguments.keys.join(', ')})',
            ));
          });

        case ToolProgressEvent(:final text):
          setState(() {
            _messages.add(_ChatMessage(role: 'status', text: text));
          });

        case SubagentEvent(:final goal, :final agentType, :final status):
          setState(() {
            _messages.add(_ChatMessage(
              role: 'status',
              text: '🤖 $agentType ($status): $goal',
            ));
          });

        case FinishEvent(:final finishReason): {
          // finishReason is unused but must be matched to satisfy sealed class exhaustiveness
          final _ = finishReason;
        }
          // Done — stop streaming indicator
          setState(() {
            _isProcessing = false;
          });

        case ErrorEvent(:final error):
          setState(() {
            _messages.add(_ChatMessage(role: 'error', text: '❌ $error'));
            _isProcessing = false;
          });

        default:
          break;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Buddy'),
        actions: [
          VoiceActivityIndicator(state: _audioState, size: 36),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Audio settings',
            onPressed: _showAudioSettings,
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Personality',
            onPressed: _showPersonalityDialog,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Reset',
            onPressed: () {
              widget.agent.reset();
              setState(() {
                _messages.clear();
                _messages.add(_ChatMessage(
                  role: 'assistant',
                  text: 'Hey buddy! What can I help you with?',
                ));
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Live audio waveform visualization
          if (widget.speechProbabilityStream != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: StreamBuilder<double>(
                stream: widget.speechProbabilityStream!,
                builder: (context, snapshot) {
                  // The waveform uses its own internal state via listen(),
                  // StreamBuilder just triggers rebuilds for the stream
                  return LiveWaveform(
                    probabilityStream: widget.speechProbabilityStream!,
                    height: 36,
                    color: _audioState == AudioState.listening
                        ? const Color(0xFF2196F3)
                        : _audioState == AudioState.speaking
                            ? const Color(0xFF9C27B0)
                            : const Color(0xFF4CAF50),
                  );
                },
              ),
            ),
          // Mel spectrogram visualization
          if (widget.melSpectrogramStream != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: MelSpectrogramVisualizer(
                melStream: widget.melSpectrogramStream,
                height: 48,
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _buildMessageBubble(msg, theme);
              },
            ),
          ),
          if (_isProcessing)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('"'"'Thinking...'"'"', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(top: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: const InputDecoration(
                      hintText: '"'"'Type or speak...'"'"',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    onSubmitted: _isProcessing ? null : _sendMessage,
                    textInputAction: TextInputAction.send,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filled(
                  icon: Icon(_isProcessing ? Icons.stop : Icons.send),
                  onPressed: _isProcessing
                      ? () { widget.agent.cancel(); setState(() => _isProcessing = false); }
                      : () => _sendMessage(_inputController.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(_ChatMessage msg, ThemeData theme) {
    final alignment = msg.role == '"'"'user'"'"' ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bgColor = msg.role == '"'"'user'"'"'
        ? theme.colorScheme.primaryContainer
        : msg.role == '"'"'error'"'"'
            ? theme.colorScheme.errorContainer
            : msg.role == '"'"'tool_call'"'"' || msg.role == '"'"'tool_result'"'"'
                ? theme.colorScheme.surfaceContainerHighest
                : msg.role == '"'"'reasoning'"'"'
                    ? theme.colorScheme.surfaceContainerLow
                    : theme.colorScheme.surfaceContainerLow;
    final textStyle = msg.role == '"'"'reasoning'"'"'
        ? theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)
        : msg.role == '"'"'status'"'"'
            ? theme.textTheme.bodySmall?.copyWith(color: Colors.grey)
            : theme.textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(18)),
            child: Text(msg.text, style: textStyle),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Future<void> _showPersonalityDialog() async {
    final dials = widget.personality.dials;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('"'"'Personality'"'"'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: dials.map((d) => Text('"'"'$d: ${widget.personality.get(d)}'"'"')).toList(),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('"'"'Close'"'"'))],
      ),
    );
  }
}

class _ChatMessage {
  final String role;
  final String text;
  final bool isStreaming;
  _ChatMessage({required this.role, required this.text, this.isStreaming = false});
}
