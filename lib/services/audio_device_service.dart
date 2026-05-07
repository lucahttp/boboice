import 'package:win32audio/win32audio.dart';

/// Audio device info wrapper.
class DeviceInfo {
  final String id;
  final String name;
  final bool isActive;
  DeviceInfo({required this.id, required this.name, required this.isActive});
}

/// Service for enumerating and selecting audio input/output devices.
class AudioDeviceService {
  List<DeviceInfo> _inputDevices = [];
  List<DeviceInfo> _outputDevices = [];
  String? _selectedInputId;
  String? _selectedOutputId;

  List<DeviceInfo> get inputDevices => _inputDevices;
  List<DeviceInfo> get outputDevices => _outputDevices;
  String? get selectedInputId => _selectedInputId;
  String? get selectedOutputId => _selectedOutputId;

  /// Load all input (microphone) and output (speaker) devices.
  Future<void> loadDevices() async {
    final inputs = await Audio.enumDevices(AudioDeviceType.input) ?? [];
    _inputDevices = inputs
        .map((d) => DeviceInfo(id: d.id, name: d.name, isActive: d.isActive))
        .toList();

    final outputs = await Audio.enumDevices(AudioDeviceType.output) ?? [];
    _outputDevices = outputs
        .map((d) => DeviceInfo(id: d.id, name: d.name, isActive: d.isActive))
        .toList();

    // Default to active device for each category
    if (_selectedInputId == null && _inputDevices.isNotEmpty) {
      final active = _inputDevices.where((d) => d.isActive).toList();
      _selectedInputId = active.isNotEmpty ? active.first.id : _inputDevices.first.id;
    }
    if (_selectedOutputId == null && _outputDevices.isNotEmpty) {
      final active = _outputDevices.where((d) => d.isActive).toList();
      _selectedOutputId = active.isNotEmpty ? active.first.id : _outputDevices.first.id;
    }
  }

  void selectInput(String id) => _selectedInputId = id;
  void selectOutput(String id) => _selectedOutputId = id;

  DeviceInfo? get selectedInput =>
      _inputDevices.where((d) => d.id == _selectedInputId).firstOrNull;

  DeviceInfo? get selectedOutput =>
      _outputDevices.where((d) => d.id == _selectedOutputId).firstOrNull;
}
