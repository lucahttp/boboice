#!/usr/bin/env python3
"""
Generate synthetic audio test data for buddy_app wake word testing.
Creates PCM s16le (16-bit mono 16kHz) files simulating:
- "hey buddy" wake word patterns (should trigger detection)
- Silence / background noise (should NOT trigger)
- Mixed audio with/without wake word

Generates .pcm files directly readable by the ONNX pipeline.
"""
import struct
import math
import os

SAMPLE_RATE = 16000
BITS_PER_SAMPLE = 16
NUM_CHANNELS = 1

# 16kHz s16le PCM: each sample is 2 bytes, little-endian
SAMPLE_SIZE = 2

def samples_to_pcm(samples: list[float]) -> bytes:
    """Convert float32 samples [-1, 1] to 16-bit PCM little-endian bytes."""
    pcm = bytearray()
    for s in samples:
        s = max(-1.0, min(1.0, s))
        s16 = int(s * 32767)
        pcm += struct.pack('<h', s16)
    return bytes(pcm)

def pcm_to_samples(pcm: bytes) -> list[float]:
    """Convert 16-bit PCM little-endian bytes to float32 samples [-1, 1]."""
    samples = []
    for i in range(0, len(pcm) - 1, 2):
        s16 = struct.unpack_from('<h', pcm, i)[0]
        samples.append(s16 / 32768.0)
    return samples

def generate_silence(duration_sec: float) -> bytes:
    """Generate silence."""
    num_samples = int(SAMPLE_RATE * duration_sec)
    return samples_to_pcm([0.0] * num_samples)

def generate_sine(freq_hz: float, duration_sec: float, amplitude: float = 0.3) -> bytes:
    """Generate a sine wave."""
    num_samples = int(SAMPLE_RATE * duration_sec)
    samples = []
    for i in range(num_samples):
        t = i / SAMPLE_RATE
        samples.append(amplitude * math.sin(2 * math.pi * freq_hz * t))
    return samples_to_pcm(samples)

def generate_noise(duration_sec: float, amplitude: float = 0.01) -> bytes:
    """Generate white noise."""
    import random
    num_samples = int(SAMPLE_RATE * duration_sec)
    samples = [amplitude * (random.random() * 2 - 1) for _ in range(num_samples)]
    return samples_to_pcm(samples)

def generate_hey_buddy_speech(duration_sec: float = 1.5, amplitude: float = 0.4) -> bytes:
    """
    Approximate "hey buddy" formants as overlapping sine waves.
    Simple multi-frequency synthesis mimicking voiced speech formants.
    This is a STYLIZED synthetic approximation for testing - not real speech.
    
    Formants for "hey" (~F1=500, F2=1850, F3=2600) and "buddy" (~F1=700, F2=1200, F3=2400)
    """
    num_samples = int(SAMPLE_RATE * duration_sec)
    samples = [0.0] * num_samples
    
    # "hey" portion (first 40% of duration)
    hey_end = int(num_samples * 0.4)
    for i in range(hey_end):
        t = i / SAMPLE_RATE
        # Amplitude envelope: quick ramp up, slow decay
        env = min(1.0, i / (SAMPLE_RATE * 0.02)) * math.exp(-i / (SAMPLE_RATE * 0.1))
        f1 = 500; f2 = 1850; f3 = 2600
        s = (0.5 * math.sin(2*math.pi*f1*t) +
             0.3 * math.sin(2*math.pi*f2*t) +
             0.15 * math.sin(2*math.pi*f3*t))
        samples[i] += amplitude * env * s
    
    # "buddy" portion (40%-90%)
    buddy_start = int(num_samples * 0.4)
    buddy_end = int(num_samples * 0.9)
    for i in range(buddy_start, buddy_end):
        t = i / SAMPLE_RATE
        env = min(1.0, (i - buddy_start) / (SAMPLE_RATE * 0.02)) * math.exp(-(i - buddy_start) / (SAMPLE_RATE * 0.12))
        f1 = 700; f2 = 1200; f3 = 2400
        s = (0.5 * math.sin(2*math.pi*f1*t) +
             0.3 * math.sin(2*math.pi*f2*t) +
             0.15 * math.sin(2*math.pi*f3*t))
        samples[i] += amplitude * env * s
    
    return samples_to_pcm(samples)

def generate_speech_like(duration_sec: float, amplitude: float = 0.35) -> bytes:
    """
    Generic speech-like signal using formants.
    Used as non-wake-word speech.
    """
    num_samples = int(SAMPLE_RATE * duration_sec)
    samples = [0.0] * num_samples
    
    # Vary formants over time to sound like generic speech
    chunk_size = int(SAMPLE_RATE * 0.1)  # 100ms chunks
    for chunk_idx in range(num_samples // chunk_size):
        start = chunk_idx * chunk_size
        end = min(start + chunk_size, num_samples)
        f1 = 400 + 300 * math.sin(chunk_idx * 0.5)
        f2 = 1200 + 600 * math.sin(chunk_idx * 0.3)
        f3 = 2500 + 400 * math.sin(chunk_idx * 0.7)
        for i in range(start, end):
            t = i / SAMPLE_RATE
            env = 0.5 + 0.5 * math.sin(2 * math.pi * i / num_samples)
            s = (0.5 * math.sin(2*math.pi*f1*t) +
                 0.3 * math.sin(2*math.pi*f2*t) +
                 0.1 * math.sin(2*math.pi*f3*t))
            samples[i] += amplitude * env * s
    
    return samples_to_pcm(samples)

def write_pcm_file(path: str, data: bytes):
    """Write raw PCM data to file."""
    with open(path, 'wb') as f:
        f.write(data)
    print(f"  wrote: {path} ({len(data)} bytes, {len(data)//SAMPLE_SIZE} samples, {len(data)//SAMPLE_SIZE/SAMPLE_RATE:.2f}s)")

def main():
    output_dir = os.path.join(os.path.dirname(__file__), 'test_data')
    os.makedirs(output_dir, exist_ok=True)
    
    print(f"Generating synthetic audio test data in: {output_dir}")
    
    # 1. Silence
    print("\n[Silence]")
    write_pcm_file(os.path.join(output_dir, 'silence_1s.pcm'), generate_silence(1.0))
    write_pcm_file(os.path.join(output_dir, 'silence_3s.pcm'), generate_silence(3.0))
    
    # 2. Hey buddy (the target wake word)
    print("\n[Hey buddy wake word]")
    write_pcm_file(os.path.join(output_dir, 'hey_buddy_short.pcm'), generate_hey_buddy_speech(1.0))
    write_pcm_file(os.path.join(output_dir, 'hey_buddy_normal.pcm'), generate_hey_buddy_speech(1.5))
    write_pcm_file(os.path.join(output_dir, 'hey_buddy_long.pcm'), generate_hey_buddy_speech(2.0))
    
    # 3. Non-wake-word speech
    print("\n[Non-wake-word speech]")
    write_pcm_file(os.path.join(output_dir, 'speech_generic_1s.pcm'), generate_speech_like(1.0))
    write_pcm_file(os.path.join(output_dir, 'speech_generic_2s.pcm'), generate_speech_like(2.0))
    write_pcm_file(os.path.join(output_dir, 'speech_generic_3s.pcm'), generate_speech_like(3.0))
    
    # 4. Noise
    print("\n[Noise]")
    write_pcm_file(os.path.join(output_dir, 'noise_1s.pcm'), generate_noise(1.0))
    
    # 5. Mixed: silence + hey buddy + silence
    print("\n[Mixed: silence + wake word + silence]")
    mixed = (generate_silence(0.5) + 
             generate_hey_buddy_speech(1.5) + 
             generate_silence(0.5))
    write_pcm_file(os.path.join(output_dir, 'mixed_silence_wake_silence.pcm'), mixed)
    
    # 6. Mixed: noise + speech (no wake word)
    print("\n[Mixed: noise + speech (no wake word)]")
    mixed2 = (generate_noise(0.3) + 
              generate_speech_like(1.0) + 
              generate_noise(0.3))
    write_pcm_file(os.path.join(output_dir, 'mixed_noise_speech.pcm'), mixed2)
    
    # 7. Two wake words back to back
    print("\n[Double wake word]")
    double_wb = (generate_silence(0.3) + 
                 generate_hey_buddy_speech(1.5) + 
                 generate_silence(0.2) +
                 generate_hey_buddy_speech(1.5))
    write_pcm_file(os.path.join(output_dir, 'double_wake_word.pcm'), double_wb)
    
    # 8. Very short audio chunks (like real mic input)
    print("\n[Short chunks for pipeline testing]")
    chunk_100ms = int(SAMPLE_RATE * 0.1)
    hb_short = generate_hey_buddy_speech(0.3)
    for i in range(min(10, len(hb_short) // (chunk_100ms * 2))):
        chunk = hb_short[i * chunk_100ms * 2 : (i + 1) * chunk_100ms * 2]
        if len(chunk) == chunk_100ms * 2:
            write_pcm_file(os.path.join(output_dir, f'chunk_heybuddy_{i:02d}.pcm'), chunk)
    
    # 9. A "trigger" file: short burst that should definitely trigger
    print("\n[Trigger pattern - loud hey buddy]")
    write_pcm_file(os.path.join(output_dir, 'trigger_hey_buddy.pcm'), generate_hey_buddy_speech(1.0, amplitude=0.7))
    
    print(f"\nDone. {len(os.listdir(output_dir))} files generated.")

if __name__ == '__main__':
    main()