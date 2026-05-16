# Buddy - Voice AI Assistant

## Overview

Buddy is a Windows voice AI assistant built with Flutter and ONNX runtime for real-time wake word detection and speech recognition.

## Architecture

```
[Mic] → [VAD] → [Wake Word] → [ASR] → [Response]
         ↓
      (speech detected)
```

## Key Components

### Wake Word Detection
- Model: `wav2vec2.onnx` (embedding) + `keyword.onnx` (classification)
- Wake phrase: "hey buddy"
- Processing: 76-frame windows with stride 8
- Threshold: 0.5 probability

### Voice Activity Detection (VAD)
- Model: `silero.onnx`
- Sample rate: 16kHz
- Stateful: maintains h/c hidden states between calls

### Automatic Speech Recognition (ASR)
- Models: `mel-spectrogram.onnx` + `encoder_new.onnx` + `decoder_new.onnx`
- Engine: Whisper-base from HuggingFace
- Input: 16kHz Float32 PCM audio
- Output: Text transcription

### Audio Pipeline
- Buffer chunks: 2048 samples per chunk
- Min samples for ASR: 160000 (10 seconds)
- Max recording: 30 seconds

## Configuration

### Paths
- Models: `%APPDATA%\Buddy\models\`
- Whisper: `%APPDATA%\Buddy\models\whisper\`
- VAD: `%APPDATA%\Buddy\models\vad\`
- Wake: `%APPDATA%\Buddy\models\wake\`

### Audio Settings
- Sample rate: 16000 Hz
- Channels: 1 (mono)
- Format: Int16 PCM

## States

### AudioManager States
- `idle`: Waiting for wake word
- `wakeWordDetected`: Wake word triggered, capturing speech
- `processing`: Finalizing ASR transcription
- `responding`: Processing user query

### Pipeline States
- `listening`: VAD inactive
- `speaking`: VAD active (speech detected)

## Build & Run

```powershell
cd c:\Users\lucas\bovoice\buddy_app
flutter build windows --debug
flutter run -d windows
```

## Known Issues

- Decoder requires SOT token (50258) for initialization
- Min 10s audio needed before ASR processes