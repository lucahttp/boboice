import 'tool.dart';

class ToolRegistry {
  final List<Tool> _tools = [];

  void registerAll(List<Tool> tools) {
    _tools.addAll(tools);
  }

  List<Tool> get all => List.unmodifiable(_tools);
}