"""Original continuous printer/paper foley; deterministic and dependency-free."""
from pathlib import Path
import math
import random
import struct
import wave

SAMPLE_RATE = 22050
FEED_DURATION = 2.4  # Checked against ReceiptMotionTiming by the native test.
TEAR_DURATION = 0.8  # 0–140ms tension, 140–340ms rip, then quiet release.
root = Path(__file__).resolve().parents[1] / "Resources"
root.mkdir(exist_ok=True)

def write(name, duration, tear=False):
    rng = random.Random(91 if tear else 37)
    samples = []
    low = 0.0
    # Nonperiodic fibre breaks: sharp attacks with short, uneven decays.
    fibres = [(0.14 + 0.20 * (j / 30) ** 0.82, rng.uniform(0.35, 1.0), rng.uniform(0.0015, 0.006)) for j in range(31)] if tear else []
    motor_phase = 0.0
    gear_phase = 0.0
    for i in range(round(duration * SAMPLE_RATE)):
        t = i / SAMPLE_RATE
        white = rng.uniform(-1, 1)
        low += 0.23 * (white - low)
        if tear:
            # Stretch: a restrained paper rub. Rip: a dry high-frequency
            # fracture, not a one-second hiss or a periodically gated buzz.
            stretch = max(0.0, math.sin(math.pi * min(1, t / 0.14))) ** 2 if t < 0.14 else 0
            grain = sum(amplitude * math.exp(-(t - onset) / decay) for onset, amplitude, decay in fibres if 0 <= t - onset < 0.045)
            rip = max(0, math.sin(math.pi * (t - 0.14) / 0.20)) if 0.14 <= t <= 0.34 else 0
            flutter = math.sin(math.pi * (t - 0.34) / 0.46) ** 2 if t >= 0.34 else 0
            flutter *= math.exp(-8 * max(0, t - 0.34))
            sample = 0.018 * low * stretch + (0.048 * rip + 0.058 * grain) * (white - low)
            sample += 0.035 * low * flutter
            sample *= min(1, t / 0.008, (duration - t) / 0.04)

        else:
            # Continuous roller motor, gear texture and paper friction. No
            # per-step gating, silence gaps, repeated clips or frame retriggers.
            attack = min(1.0, t / 0.065)
            release = min(1.0, (duration - t) / 0.16)
            edge = math.sin(math.pi * attack / 2) * math.sin(math.pi * release / 2)
            speed = 0.90 + 0.10 * min(1, t / 0.11)
            speed -= 0.12 * max(0, (t - duration + 0.17) / 0.17)
            motor_phase += 2 * math.pi * (198 * speed + 1.3 * math.sin(2 * math.pi * 2.1 * t)) / SAMPLE_RATE
            gear_phase += 2 * math.pi * 67 * speed / SAMPLE_RATE
            motor = 0.033 * math.sin(motor_phase) + 0.014 * math.sin(3 * motor_phase + 0.2) + 0.008 * math.sin(6 * motor_phase)
            friction = 0.083 * low + 0.027 * (white - low)
            mesh = 0.88 + 0.12 * math.cos(gear_phase)  # always positive
            drift = 0.96 + 0.04 * math.sin(2 * math.pi * 3.7 * t)
            sample = edge * (motor * mesh + friction) * drift
        samples.append(sample)
    peak = max(abs(x) for x in samples)
    assert peak < 0.22, "No clipping or abrupt loud UI effects"
    if tear:
        def energy(start, end):
            segment = samples[round(start * SAMPLE_RATE):round(end * SAMPLE_RATE)]
            return sum(v*v for v in segment) / len(segment)
        assert energy(0.14, 0.34) > 20 * energy(0.40, 0.75), "Rip must be crisp, followed by a quiet release"
        print(f"Crisp tear: {duration:.2f}s, 200ms fibre break, peak {peak:.3f}")
    if not tear:
        window = round(SAMPLE_RATE * 0.04)
        interior = samples[round(0.16 * SAMPLE_RATE):-round(0.20 * SAMPLE_RATE)]
        rms = [math.sqrt(sum(v*v for v in interior[i:i+window])/window) for i in range(0,len(interior)-window+1,window)]
        middle = sorted(rms)[len(rms)//2]
        assert min(rms) > 0.015 and min(rms)/middle > 0.65, "Paper feed must have no periodic dropouts"
        print(f"Continuous feed: {duration:.2f}s, minimum 40ms RMS {min(rms):.4f}, min/median {min(rms)/middle:.3f}, peak {peak:.3f}")
    with wave.open(str(root / (name + ".wav")), "wb") as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(SAMPLE_RATE)
        audio.writeframes(b"".join(struct.pack("<h", round(x * 32767)) for x in samples))

write("paper_feed", FEED_DURATION)
write("paper_tear", TEAR_DURATION, tear=True)
print("Generated continuous printer feed and paper tear UI sounds (PCM WAV).")
