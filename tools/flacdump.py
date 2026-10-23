#!/usr/bin/env python3
"""Report where the bits go in a FLAC file.

Parses the frame and subframe headers of a native FLAC stream and prints, per
frame, the channel assignment and every subframe's coding decision
(CONSTANT / VERBATIM / FIXED / LPC, order, coefficient precision and shift,
Rice partition order and parameters) together with a bit breakdown.

This exists so compression work is driven by measurement instead of guesswork:
the same PCM encoded by this project and by libFLAC can be compared decision by
decision.

Usage:
    python tools/inspect.py <file.flac> [--max-frames N]
"""

import argparse
import sys


class BitReader:
    def __init__(self, data):
        self.data = data
        self.bit = 0

    def read(self, count):
        value = 0
        for _ in range(count):
            byte = self.data[self.bit >> 3]
            value = (value << 1) | ((byte >> (7 - (self.bit & 7))) & 1)
            self.bit += 1
        return value

    def read_signed(self, count):
        value = self.read(count)
        if value >= 1 << (count - 1):
            value -= 1 << count
        return value

    def read_unary(self):
        count = 0
        while self.read(1) == 0:
            count += 1
        return count

    def align(self):
        self.bit = (self.bit + 7) & ~7


def utf8_number(reader):
    first = reader.read(8)
    if first < 0x80:
        return first
    mask = 0x40
    extra = 0
    while first & mask:
        extra += 1
        mask >>= 1
    value = first & (mask - 1)
    for _ in range(extra):
        value = (value << 6) | (reader.read(8) & 0x3F)
    return value


def parse_streaminfo(data):
    body = 8
    rate = (data[body + 10] << 12) | (data[body + 11] << 4) | (data[body + 12] >> 4)
    channels = ((data[body + 12] >> 1) & 0x7) + 1
    bits = (((data[body + 12] & 1) << 4) | (data[body + 13] >> 4)) + 1
    total = ((data[body + 13] & 0xF) << 32) | int.from_bytes(data[body + 14:body + 18], "big")
    return rate, channels, bits, total


def read_residual(reader, block_size, order, wide):
    method = reader.read(2)
    width = 5 if method == 1 else 4
    escape = 31 if method == 1 else 15
    partition_order = reader.read(4)
    partitions = 1 << partition_order
    size = block_size >> partition_order
    samples_per_partition = []
    for index in range(partitions):
        samples_per_partition.append(size - order if index == 0 else size)
    bits = 6
    params = []
    for count in samples_per_partition:
        parameter = reader.read(width)
        params.append(parameter)
        bits += width
        if parameter == escape:
            raw = reader.read(5)
            bits += 5 + count * raw
            reader.read(count * raw)
        else:
            for _ in range(count):
                quotient = reader.read_unary()
                reader.read(parameter)
                bits += quotient + 1 + parameter
    return bits, method, partition_order, params


def inspect(path, max_frames):
    data = open(path, "rb").read()
    if data[:4] != b"fLaC":
        raise SystemExit("not a native FLAC stream")
    rate, channels, bits, total = parse_streaminfo(data)
    print(f"file     : {path}")
    print(f"streaminfo: rate={rate} channels={channels} bits={bits} total_samples={total}")
    position = 4
    while position < len(data):
        header = data[position]
        last = header & 0x80
        length = int.from_bytes(data[position + 1:position + 4], "big")
        position += 4 + length
        if last:
            break
    frames = 0
    while position < len(data) - 1 and frames < max_frames:
        reader = BitReader(data[position:])
        sync = reader.read(14)
        if sync != 0x3FFE:
            print(f"frame {frames}: sync mismatch at offset {position}, stopping")
            break
        reader.read(1)
        blocking = reader.read(1)
        block_code = reader.read(4)
        rate_code = reader.read(4)
        channel_code = reader.read(4)
        depth_code = reader.read(3)
        reader.read(1)
        number = utf8_number(reader)
        if block_code == 6:
            block_size = reader.read(8) + 1
        elif block_code == 7:
            block_size = reader.read(16) + 1
        elif block_code == 1:
            block_size = 192
        elif 2 <= block_code <= 5:
            block_size = 576 << (block_code - 2)
        else:
            block_size = 256 << (block_code - 8)
        if rate_code == 12:
            reader.read(8)
        elif rate_code in (13, 14):
            reader.read(16)
        reader.read(8)  # header CRC-8
        header_bits = reader.bit
        names = {0: "mono", 1: "stereo L/R", 8: "left/side", 9: "right/side", 10: "mid/side"}
        assignment = names.get(channel_code, f"code {channel_code}")
        if channel_code <= 7:
            subframes = channel_code + 1
            depths = [bits] * subframes
        else:
            subframes = 2
            side = bits + 1
            if channel_code == 8:
                depths = [bits, side]
            elif channel_code == 9:
                depths = [side, bits]
            else:
                depths = [bits, side]
        decisions = []
        for channel in range(subframes):
            zero = reader.read(1)
            kind = reader.read(6)
            wasted = reader.read(1)
            if wasted:
                reader.read_unary()
            before = reader.bit
            if kind == 0:
                reader.read(depths[channel])
                decisions.append(f"CONSTANT({depths[channel]}b)")
            elif kind == 1:
                reader.read(block_size * depths[channel])
                decisions.append(f"VERBATIM")
            elif kind >= 32:
                order = kind - 32 + 1
                reader.read(order * depths[channel])
                precision = reader.read(4) + 1
                shift = reader.read_signed(5)
                reader.read(order * precision)
                residual_bits, method, partition_order, params = read_residual(
                    reader, block_size, order, True)
                decisions.append(
                    f"LPC o={order} prec={precision} shift={shift} "
                    f"po={partition_order} rice={params[:4]}{'...' if len(params) > 4 else ''} "
                    f"res={residual_bits}b")
            else:
                order = kind - 8
                reader.read(order * depths[channel])
                residual_bits, method, partition_order, params = read_residual(
                    reader, block_size, order, False)
                decisions.append(
                    f"FIXED o={order} po={partition_order} "
                    f"rice={params[:4]}{'...' if len(params) > 4 else ''} res={residual_bits}b")
            used = reader.bit - before
            if decisions:
                decisions[-1] += f" sub={used}b"
        reader.align()
        footer = reader.read(16)
        consumed = reader.bit // 8
        if frames == 0:
            print(f"frame 0  : assignment={assignment} block={block_size} "
                  f"header={header_bits}b total={consumed}B")
            for channel, decision in enumerate(decisions):
                print(f"           ch{channel}: {decision}")
        frames += 1
        position += consumed

    print(f"frames parsed: {frames}")
    if frames:
        print("note: only frame 0 is printed in detail; headers of every frame were parsed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--max-frames", type=int, default=1)
    args = parser.parse_args()
    inspect(args.path, args.max_frames)
    return 0


if __name__ == "__main__":
    sys.exit(main())
