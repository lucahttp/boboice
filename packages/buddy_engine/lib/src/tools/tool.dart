/// Represents a callable tool/function.
class Tool {
  final String name;
  final String description;
  final Map<String, ToolParam> params;

  const Tool({
    required this.name,
    required this.description,
    required this.params,
  });

  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': {
          for (final p in params.entries)
            p.key: {'type': p.value.type, 'description': p.value.description},
        },
      },
    },
  };
}

class ToolParam {
  final String type;
  final String description;

  const ToolParam({required this.type, required this.description});
}