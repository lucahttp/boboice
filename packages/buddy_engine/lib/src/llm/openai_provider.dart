import 'dart:convert';
import 'package:http/http.dart' as http;
import 'llm_provider.dart';

/// OpenAI-compatible LLM provider.
class OpenAiProvider implements LlmProvider {
  final String baseUrl;
  final String apiKey;
  final String defaultModel;

  OpenAiProvider({
    required this.baseUrl,
    required this.apiKey,
    required this.defaultModel,
  });

  @override
  Future<String> complete(List<Map<String, String>> messages, {
    String? model,
    double? temperature,
  }) async {
    final uri = Uri.parse('$baseUrl/chat/completions');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model ?? defaultModel,
        'messages': messages,
        if (temperature != null) 'temperature': temperature,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('LLM error: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] as String;
  }
}