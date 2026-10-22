#!/usr/bin/env python3
"""Reproducible verification for moonflac-encoder.

Two checks:

  matrix     Encode synthetic signals, decode them with libsndfile (through
             Python `soundfile`) and compare the decoded PCM digest against the
             one the encoder wrote into STREAMINFO. Bit exact or it fails.

  benchmark  Encode the same PCM with this encoder and with libsndfile's FLAC
             writer, and report the size difference. This is the measurement
             behind the "known gap" line in the README.

Requirements: the MoonBit toolchain on PATH (or MOON set to the binary) and
`soundfile` + `numpy` for Python. Run from anywhere; paths are resolved against
the repository root.
"""

import argparse
import base64
import hashlib
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOON = os.environ.get("MOON") or os.path.expanduser("~/.moon/bin/moon")


def encode_ours(rate, channels, bits, frames, kind):
    """Run the encoder's `gen` command and return the FLAC bytes."""
    proc = subprocess.run(
        [MOON, "run", "cmd/main", "--", "gen", str(rate), str(channels),
         str(bits), str(frames), str(kind)],
        cwd=ROOT, capture_output=True, text=True,
    )
    lines = proc.stdout.splitlines()
    if "FLACBEGIN" not in lines:
        raise RuntimeError(f"encode failed: {proc.stderr.strip()[:200]}")
    return base64.b64decode(lines[lines.index("FLACBEGIN") + 1])


def streaminfo_digest(flac):
    """The STREAMINFO MD5, which covers the unencoded PCM."""
    return flac[8 + 18:8 + 34].hex()


def decoded_digest(flac, bits):
    """Decode with libsndfile and rebuild the PCM bytes FLAC's digest covers."""
    import soundfile as sf

    with tempfile.NamedTemporaryFile(suffix=".flac", delete=False) as handle:
        handle.write(flac)
        path = handle.name
    try:
        data, _ = sf.read(path, dtype="int32", always_2d=True)
    finally:
        os.unlink(path)
    width = (bits + 7) // 8
    shift = 32 - bits
    raw = bytearray()
    for value in data.reshape(-1):
        raw += ((int(value) >> shift) & ((1 << bits) - 1)).to_bytes(width, "little")
    return hashlib.md5(bytes(raw)).hexdigest()


def run_matrix(cases):
    failures = 0
    print(f"{'rate':>6} {'ch':>3} {'bits':>5} {'frames':>7} {'kind':>5}  result")
    for rate, channels, bits, frames, kind in cases:
        try:
            flac = encode_ours(rate, channels, bits, frames, kind)
            expected = streaminfo_digest(flac)
            actual = decoded_digest(flac, bits)
        except Exception as error:  # noqa: BLE001 - report and keep going
            failures += 1
            print(f"{rate:>6} {channels:>3} {bits:>5} {frames:>7} {kind:>5}  FAIL {error}")
            continue
        ok = expected == actual
        failures += 0 if ok else 1
        print(f"{rate:>6} {channels:>3} {bits:>5} {frames:>7} {kind:>5}  "
              f"{'ok' if ok else 'MISMATCH'}")
    print(f"\ncases={len(cases)} failures={failures}")
    return 1 if failures else 0


def build_signal(kind, channels, frames, rate):
    import numpy as np

    time = np.arange(frames) / rate
    if kind == "sine":
        base = 0.5 * np.sin(2 * np.pi * 440 * time)
    elif kind == "two-tone":
        base = 0.3 * np.sin(2 * np.pi * 2200 * time) + 0.05 * np.sin(2 * np.pi * 97 * time)
    elif kind == "harmonics":
        base = sum(0.2 / (k + 1) * np.sin(2 * np.pi * 220 * (k + 1) * time) for k in range(6))
    elif kind == "sweep":
        frequency = 100 + 4000 * time / time[-1]
        base = 0.4 * np.sin(2 * np.pi * np.cumsum(frequency) / rate)
    elif kind == "noise":
        base = 0.3 * np.random.default_rng(7).standard_normal(frames)
    else:
        raise ValueError(f"unknown signal {kind}")
    if channels == 1:
        return np.clip(base, -1, 1)
    return np.stack([np.clip(base, -1, 1), np.clip(np.roll(base, 3) * 0.9, -1, 1)], axis=1)


def run_benchmark(frames, rate):
    import numpy as np
    import soundfile as sf

    print(f"{'signal':10} {'ch':>2} {'raw':>7} {'ours':>7} {'libFLAC':>8} {'vs ref':>8}")
    for kind in ("sine", "two-tone", "harmonics", "sweep", "noise"):
        for channels in (1, 2):
            pcm = build_signal(kind, channels, frames, rate)
            wav_path = os.path.join(tempfile.gettempdir(), "moonflac_bench_in.wav")
            sf.write(wav_path, pcm, rate, subtype="PCM_16")
            payload = base64.b64encode(open(wav_path, "rb").read()).decode()
            env = dict(os.environ)
            env["MOONFLAC_WAV_B64"] = payload
            proc = subprocess.run(
                [MOON, "run", "cmd/main", "--", "encode", "@MOONFLAC_WAV_B64"],
                cwd=ROOT, capture_output=True, text=True, env=env,
            )
            lines = proc.stdout.splitlines()
            if "FLACBEGIN" not in lines:
                print(f"{kind:10} {channels:>2}  encode failed")
                continue
            ours = len(base64.b64decode(lines[lines.index("FLACBEGIN") + 1]))
            ref_path = os.path.join(tempfile.gettempdir(), "moonflac_bench_ref.flac")
            sf.write(ref_path, pcm, rate, format="FLAC", subtype="PCM_16")
            ref = os.path.getsize(ref_path)
            raw = len(pcm.astype("<i2").tobytes())
            print(f"{kind:10} {channels:>2} {raw:7d} {ours:7d} {ref:8d} "
                  f"{(ours - ref) / ref * 100:+7.1f}%")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("matrix", "benchmark"))
    parser.add_argument("--frames", type=int, default=4096)
    parser.add_argument("--rate", type=int, default=44100)
    args = parser.parse_args()

    if args.check == "matrix":
        cases = [
            (args.rate, channels, bits, frames, kind)
            for channels in (1, 2)
            for bits in (16, 24)
            for kind in (0, 2, 4)
            for frames in (1, 4095, 4096, 4097)
        ]
        return run_matrix(cases)
    # the benchmark feeds the WAV through the environment, so keep it small
    return run_benchmark(min(args.frames, 8820), args.rate)


if __name__ == "__main__":
    sys.exit(main())
