import 'dart:convert';
import 'dart:io';

/// Maps Whisper token IDs to text strings.
/// Loads tokenizer.json from the HuggingFace whisper-tiny.en model.
class WhisperTokenizer {
  final Map<int, String> _idToToken = {};
  final Set<int> _specialIds = {};
  bool _loaded = false;

  /// Special token constants
  static const int sot = 50257; // <|startoftranscript|>
  static const int eot = 50256; // <|endoftext|>
  static const int en = 50258; // <|en|>
  static const int transcribe = 50358; // <|transcribe|>
  static const int notimestamps = 50362; // <|notimestamps|>

  /// Initial prompt tokens: <|startoftranscript|> <|en|> <|transcribe|> <|notimestamps|>
  static const List<int> promptTokens = [sot, en, transcribe, notimestamps];

  /// Load tokenizer from file path.
  Future<void> load(String path) async {
    if (_loaded) return;
    final json = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final vocab = json['model']['vocab'] as Map<String, dynamic>;
    final addedTokens = json['added_tokens'] as List<dynamic>;

    // Build id -> token map from vocab
    for (final entry in vocab.entries) {
      final id = (entry.value as num).toInt();
      _idToToken[id] = entry.key;
    }

    // Mark special tokens (timestamps and special markers)
    for (final tok in addedTokens) {
      final t = tok as Map<String, dynamic>;
      final id = (t['id'] as num).toInt();
      final content = t['content'] as String;
      if (content.startsWith('<|')) {
        _specialIds.add(id);
      }
    }

    _loaded = true;
  }

  /// Decode token IDs back to text, filtering out special tokens.
  String decode(List<int> tokenIds) {
    final buffer = StringBuffer();
    for (final id in tokenIds) {
      if (id == eot) break; // Stop at EOT
      if (_specialIds.contains(id)) continue; // Skip special tokens
      final token = _idToToken[id];
      if (token == null) continue;

      // Handle GPT-2 style byte-level tokenization
      final decoded = _decodeToken(token);
      buffer.write(decoded);
    }
    return buffer.toString().trim();
  }

  /// Decode a single GPT-2 BPE token (may contain Ġ prefix for space).
  String _decodeToken(String token) {
    // Replace GPT-2 space character with actual space
    var result = token.replaceAll('Ġ', ' ');
    // Handle byte-level encodings (bytes that get mapped to unicode)
    // For simplicity, we use the token as-is; GPT-2 byte fallback
    // characters like \u0120 etc. are handled by the replace above
    return result;
  }
}
