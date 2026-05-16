import 'dart:async';
import 'package:flutter/foundation.dart';
import '../llm/llm_provider.dart';
import '../personality/personality.dart';
import '../tools/tool_registry.dart';
import '../llm/abort_signal.dart';

/// Base class for all agent events.
sealed class AgentEvent {}

class ReasoningDeltaEvent extends AgentEvent {
  final String delta;
  ReasoningDeltaEvent(this.delta);
}

class TextDeltaEvent extends AgentEvent {
  final String delta;
  TextDeltaEvent(this.delta);
}

class TextEndEvent extends AgentEvent {
  final String id;
  TextEndEvent(this.id);
}

class ToolCallEvent extends AgentEvent {
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;
  ToolCallEvent({required this.callId, required this.name, required this.arguments});
}

class ToolProgressEvent extends AgentEvent {
  final String text;
  ToolProgressEvent(this.text);
}

class SubagentEvent extends AgentEvent {
  final String goal;
  final String agentType;
  final String status;
  SubagentEvent({required this.goal, required this.agentType, required this.status});
}

class FinishEvent extends AgentEvent {
  final String finishReason;
  FinishEvent(this.finishReason);
}

class ErrorEvent extends AgentEvent {
  final String error;
  ErrorEvent(this.error);
}

/// Voice AI agent.
class VoiceAgent {
  final LlmProvider _llm;
  final ToolRegistry _toolRegistry;
  final Personality _personality;
  final AbortSignal _abortSignal;
  final List<String> _queue = [];
  bool _initialized = false;
  bool _cancelled = false;

  VoiceAgent({
    required LlmProvider llm,
    required ToolRegistry toolRegistry,
    required Personality personality,
    required AbortSignal abortSignal,
  })  : _llm = llm,
        _toolRegistry = toolRegistry,
        _personality = personality,
        _abortSignal = abortSignal;

  void initialize() {
    _initialized = true;
  }

  void enqueue(String text) {
    _queue.add(text);
    _processQueue();
  }

  Stream<AgentEvent> process(String text) async* {
    yield TextDeltaEvent(text);
    yield FinishEvent('stop');
  }

  void cancel() {
    _cancelled = true;
  }

  void reset() {
    _cancelled = false;
  }

  Future<void> _processQueue() async {
    if (_queue.isEmpty || !_initialized) return;
    final text = _queue.removeAt(0);
    if (_abortSignal.isAborted) return;

    try {
      final response = await _llm.complete([
        {'role': 'user', 'content': text},
      ]);
      debugPrint('Agent response: $response');
    } catch (e) {
      debugPrint('Agent error: $e');
    }
  }
}