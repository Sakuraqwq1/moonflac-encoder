// moonflac-encoder — pure MoonBit FLAC encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
/// MSB-first bit writer. FLAC frames are a continuous bit stream, so every
/// field (including the ones that are not byte aligned) goes through here.
pub struct BitWriter {
  buffer : @buffer.Buffer
  mut current : Int32
  mut filled : Int32
}

///|
/// A fresh writer with an empty buffer.
pub fn BitWriter::new() -> BitWriter {
  BitWriter::{
    buffer: @buffer.Buffer::Buffer(size_hint=8192),
    current: 0,
    filled: 0,
  }
}

///|
/// Append a single bit.
pub fn BitWriter::write_bit(self : BitWriter, bit : Int32) -> Unit {
  self.current = (self.current << 1) | (bit & 1)
  self.filled = self.filled + 1
  if self.filled == 8 {
    self.buffer.write_byte(self.current.to_byte())
    self.current = 0
    self.filled = 0
  }
}

///|
/// Append the low `count` bits of `value`, most significant first.
pub fn BitWriter::write_bits(
  self : BitWriter,
  value : Int64,
  count : Int32,
) -> Unit {
  // Whole bytes go straight to the buffer when the writer is aligned: residual
  // remainders and sample values are most of FLAC's bits, and the per-bit path
  // costs a method call each.
  let mut remaining = count
  let mut shift = count
  while remaining >= 8 && self.filled == 0 {
    shift = shift - 8
    self.buffer.write_byte(((value >> shift) & 0xFFL).to_byte())
    remaining = remaining - 8
  }
  let mut index = remaining - 1
  while index >= 0 {
    self.write_bit(((value >> index) & 1L).to_int())
    index = index - 1
  }
}

///|
/// Append `value` as a `count` bit two's complement number.
///
/// Values wider than the target width are truncated, which is what the FLAC
/// subframe encoders need when they narrow a residual to its Rice width.
pub fn BitWriter::write_signed(
  self : BitWriter,
  value : Int64,
  count : Int32,
) -> Unit {
  if count <= 0 {
    return
  }
  let mask = (1L << count) - 1L
  self.write_bits(value & mask, count)
}

///|
/// Append `value` zeros followed by a one (FLAC's unary code).
pub fn BitWriter::write_unary(self : BitWriter, value : Int32) -> Unit {
  let mut remaining = value
  while remaining >= 8 && self.filled == 0 {
    self.buffer.write_byte(0x00)
    remaining = remaining - 8
  }
  for _index = 0; _index < remaining; _index = _index + 1 {
    self.write_bit(0)
  }
  self.write_bit(1)
}

///|
/// Pad the current byte with zeros so the next write starts byte aligned.
pub fn BitWriter::align(self : BitWriter) -> Unit {
  if self.filled > 0 {
    let shift = 8 - self.filled
    self.buffer.write_byte(((self.current << shift) & 0xFF).to_byte())
    self.current = 0
    self.filled = 0
  }
}

///|
/// Append raw bytes. The writer must be byte aligned, which the frame layout
/// guarantees at every point where this is used.
pub fn BitWriter::write_bytes(self : BitWriter, data : Bytes) -> Unit {
  self.align()
  for index = 0; index < data.length(); index = index + 1 {
    self.buffer.write_byte(data.at(index))
  }
}

///|
/// Flush the trailing partial byte and hand back the bytes written so far.
pub fn BitWriter::finish(self : BitWriter) -> Bytes {
  self.align()
  self.buffer.to_bytes()
}

///|
/// Number of bits written so far, including the partial byte in flight.
pub fn BitWriter::bit_length(self : BitWriter) -> Int64 {
  (self.buffer.length() * 8).to_int64() + self.filled.to_int64()
}
