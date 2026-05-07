//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_onnxruntime/flutter_onnxruntime_plugin.h>
#include <speech_to_text_windows/speech_to_text_windows.h>
#include <win32audio/win32audio_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterOnnxruntimePluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterOnnxruntimePlugin"));
  SpeechToTextWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("SpeechToTextWindows"));
  Win32audioPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("Win32audioPluginCApi"));
}
