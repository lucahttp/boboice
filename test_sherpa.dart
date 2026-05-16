import 'dart:mirrors';
import 'package:sherpa_onnx/sherpa_onnx.dart';

void main() {
  ClassMirror m1 = reflectClass(OfflineRecognizerConfig);
  for (var c in m1.declarations.values.whereType<MethodMirror>().where((m) => m.isConstructor)) {
    print('OfflineRecognizerConfig: \${c.parameters.map((p) => "\${p.simpleName}: \${p.type.simpleName}").toList()}');
  }
  
  ClassMirror m2 = reflectClass(OfflineRecognizer);
  for (var c in m2.declarations.values.whereType<MethodMirror>().where((m) => m.isConstructor)) {
    print('OfflineRecognizer: \${c.parameters.map((p) => "\${p.simpleName}: \${p.type.simpleName}").toList()}');
  }
}
