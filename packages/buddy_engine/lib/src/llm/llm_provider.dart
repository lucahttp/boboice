/// Base class for LLM providers.
abstract class LlmProvider {
  /// Send a chat completion request.
  Future<String> complete(List<Map<String, String>> messages, {
    String? model,
    double? temperature,
  });
}