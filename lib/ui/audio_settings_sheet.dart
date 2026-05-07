import 'package:flutter/material.dart';
import '../services/audio_device_service.dart';
import '../services/audio_pipeline.dart' show AudioState;
import 'widgets/voice_activity_indicator.dart';

/// Bottom sheet for audio device selection and voice state display.
class AudioSettingsSheet extends StatefulWidget {
  final AudioDeviceService deviceService;
  final AudioState voiceState;

  const AudioSettingsSheet({
    super.key,
    required this.deviceService,
    required this.voiceState,
  });

  @override
  State<AudioSettingsSheet> createState() => _AudioSettingsSheetState();
}

class _AudioSettingsSheetState extends State<AudioSettingsSheet> {
  @override
  void initState() {
    super.initState();
    widget.deviceService.loadDevices().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[400],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Voice activity indicator
          VoiceActivityIndicator(
            state: widget.voiceState,
            size: 80,
          ),
          const SizedBox(height: 8),
          VoiceStateLabel(state: widget.voiceState),
          const SizedBox(height: 24),

          const Divider(),

          // Input device selector
          _DeviceDropdown(
            label: 'Microphone',
            icon: Icons.mic,
            devices: widget.deviceService.inputDevices,
            selectedId: widget.deviceService.selectedInputId,
            onChanged: (id) {
              widget.deviceService.selectInput(id);
              setState(() {});
            },
          ),
          const SizedBox(height: 16),

          // Output device selector
          _DeviceDropdown(
            label: 'Speaker',
            icon: Icons.speaker,
            devices: widget.deviceService.outputDevices,
            selectedId: widget.deviceService.selectedOutputId,
            onChanged: (id) {
              widget.deviceService.selectOutput(id);
              setState(() {});
            },
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _DeviceDropdown extends StatelessWidget {
  final String label;
  final IconData icon;
  final List<DeviceInfo> devices;
  final String? selectedId;
  final ValueChanged<String> onChanged;

  const _DeviceDropdown({
    required this.label,
    required this.icon,
    required this.devices,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.grey[600], size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue: selectedId,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: devices.map((d) {
                  return DropdownMenuItem(
                    value: d.id,
                    child: Row(
                      children: [
                        if (d.isActive)
                          const Icon(Icons.check, size: 14, color: Colors.green),
                        if (d.isActive) const SizedBox(width: 6),
                        Flexible(child: Text(d.name, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (id) {
                  if (id != null) onChanged(id);
                },
                hint: Text('Select $label'),
                isExpanded: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
