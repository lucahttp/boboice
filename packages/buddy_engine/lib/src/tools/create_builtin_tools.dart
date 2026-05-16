import 'tool.dart';

/// Create built-in tools for the agent.
List<Tool> createBuiltinTools({
  required void Function(String dial, double value) onSetPersonality,
  required List<String> availableSkills,
}) {
  return [
    Tool(
      name: 'set_personality',
      description: 'Adjust personality dial (0.0-1.0)',
      params: {
        'dial': const ToolParam(type: 'string', description: 'Dial name'),
        'value': const ToolParam(type: 'number', description: 'Value 0.0-1.0'),
      },
    ),
  ];
}