# Buddy App

Voice-first AI companion for Windows — wake word → ASR → LLM → response.

## Architecture

```
Microphone (WASAPI)
    ↓
flutter_recorder (16kHz mono s16le PCM)
    ↓
OnnxPipeline (VAD + Wake Word via ONNX Runtime)
    ↓
Wake Word "hey buddy" detected?
    ├── Yes → Record audio buffer
    └── No  → Continue listening
    ↓
Audio buffer (Float32List)
    ↓
WhisperMelService (80-bin mel spectrogram, pure Dart FFT)
    ↓
WhisperASR (whisper-tiny.en ONNX via flutter_onnxruntime)
    ↓
Transcribed text → VoiceAgent → MiniMax M2 LLM
    ↓
Response displayed in conversation UI
```

## Key Components

| Component     | File                                            | Description                                                |
| ------------- | ----------------------------------------------- | ---------------------------------------------------------- |
| ONNX Pipeline | `services/onnx_pipeline.dart`                   | VAD (silero-vad) + Wake Word (hey-buddy) + Mel Spectrogram |
| Audio Manager | `services/onnx_audio_manager.dart`              | Orchestrates mic → pipeline → recording                    |
| Whisper ASR   | `services/whisper_asr_service.dart`             | Whisper tiny.en ONNX encoder + decoder                     |
| Mel Service   | `services/whisper_mel_service.dart`             | Pure Dart 80-bin mel spectrogram with FFT                  |
| Tokenizer     | `services/whisper_tokenizer.dart`               | HuggingFace tokenizer.json parser                          |
| Mic Capture   | `services/mic_capture_service.dart`             | WASAPI audio capture via flutter_recorder                  |
| Voice Agent   | `buddy_engine/lib/src/agent/voice_agent.dart`   | LLM orchestration with tools                               |
| LLM Provider  | `buddy_engine/lib/src/llm/openai_provider.dart` | MiniMax M2 via OpenAI-compatible API                       |

## ONNX Models

All models stored in `%APPDATA%\Buddy\models\`:

| Model                        | Size  | Purpose                               |
| ---------------------------- | ----- | ------------------------------------- |
| `silero-vad.onnx`            | 1.7MB | Voice Activity Detection              |
| `hey-buddy.onnx`             | 1.1MB | Wake word detection                   |
| `mel-spectrogram.onnx`       | 1.0MB | Mel spectrogram (wake word pipeline)  |
| `speech-embedding.onnx`      | 1.3MB | Speech embedding (wake word pipeline) |
| `whisper/encoder_model.onnx` | 31MB  | Whisper encoder                       |
| `whisper/decoder_model.onnx` | 113MB | Whisper decoder                       |
| `whisper/tokenizer.json`     | 2.3MB | Whisper tokenizer                     |

Download Whisper models:

```
https://huggingface.co/onnx-community/whisper-tiny.en/resolve/main/onnx/encoder_model.onnx
https://huggingface.co/onnx-community/whisper-tiny.en/resolve/main/onnx/decoder_model.onnx
https://huggingface.co/onnx-community/whisper-tiny.en/resolve/main/onnx/tokenizer.json
```

## Dependencies

- `flutter_onnxruntime ^1.7.0` — ONNX Runtime inference (VAD, Wake Word, Whisper)
- `flutter_recorder ^1.1.4` — WASAPI microphone capture
- `speech_to_text ^7.3.0` — Windows SAPI fallback (not used since Whisper is better)
- `buddy_engine` — Local Dart package with VoiceAgent + tools

## Running

```bash
cd buddy_app
flutter build windows --release
# Models must be in %APPDATA%\Buddy\models\
./build/windows/x64/runner/Release/buddy_app.exe
```

For dev with hot reload:

```bash
flutter run -d windows
```

## Flow

1. App starts → ONNX sessions loaded (VAD, Wake Word, Whisper encoder + decoder)
2. Microphone streaming → 2048-sample chunks → ONNX pipeline
3. VAD detects voice → Wake Word check runs continuously
4. "hey buddy" detected → audio buffer starts recording
5. VAD silence → buffer dispatched to Whisper ASR
6. Whisper: mel spectrogram → encoder → decoder autoregressive loop → text
7. Text → VoiceAgent.enqueue() → MiniMax M2 → response displayed

https://huggingface.co/models?library=onnx&pipeline_tag=automatic-speech-recognition&sort=likes
distil-whisper/distil-large-v3
