// moonflac-encoder — pure MoonBit FLAC encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
/// Incremental encoder: feed PCM as it arrives, get FLAC frames back.
///
/// The one-shot [`encode`](encode.mbt) needs the whole signal because STREAMINFO
/// carries the total sample count and the MD5 of the unencoded PCM. A stream
/// does not have either up front, so this encoder writes both fields as zero,
/// which RFC 9639 defines as "unknown". The reference `flac` tool does the same
/// when its output is not seekable. A decoder still gets a valid stream, it just
/// cannot use the digest to verify the decode.
pub struct StreamEncoder {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  mut frame_number : Int32
  buffer : Array[Int64]
  mut filled : Int32
}

///|
/// Start a stream with the given parameters. Nothing is emitted until
/// [`StreamEncoder::header`] or [`StreamEncoder::write`] is called.
pub fn StreamEncoder::new(
  sample_rate : Int32,
  channels : Int32,
  bits_per_sample : Int32,
) -> StreamEncoder raise EncodeError {
  if channels < 1 || channels > 8 {
    raise BadChannels(channels)
  }
  if bits_per_sample < 4 || bits_per_sample > 32 {
    raise BadBits(bits_per_sample)
  }
  if sample_rate <= 0 {
    raise BadSampleRate(sample_rate)
  }
  StreamEncoder::{
    sample_rate,
    channels,
    bits: bits_per_sample,
    frame_number: 0,
    buffer: Array::make(BLOCK_SIZE * channels, 0L),
    filled: 0,
  }
}

///|
/// The `fLaC` marker and the STREAMINFO block, with the sample count and PCM
/// digest left unknown. Emit this once, before the first frame.
pub fn StreamEncoder::header(self : StreamEncoder) -> Bytes {
  let out = @buffer.Buffer::Buffer(size_hint=64)
  out.write_string_utf8("fLaC")
  out.write_byte(0x80)
  out.write_byte(0x00)
  out.write_byte(0x00)
  out.write_byte(34)
  let info = @primitives.BitWriter::new()
  info.write_bits(BLOCK_SIZE.to_int64(), 16)
  info.write_bits(BLOCK_SIZE.to_int64(), 16)
  info.write_bits(0L, 24)
  info.write_bits(0L, 24)
  info.write_bits(self.sample_rate.to_int64(), 20)
  info.write_bits((self.channels - 1).to_int64(), 3)
  info.write_bits((self.bits - 1).to_int64(), 5)
  info.write_bits(0L, 36)
  let body = info.finish()
  for index = 0; index < body.length(); index = index + 1 {
    out.write_byte(body.at(index))
  }
  // Unknown digest: sixteen zero bytes.
  for _index = 0; _index < 16; _index = _index + 1 {
    out.write_byte(0x00)
  }
  out.to_bytes()
}

///|
/// Push interleaved PCM and receive whatever complete frames that produced.
///
/// The result is usually empty for small inputs: samples are buffered until a
/// full block is available, because frame size is what the format trades
/// compression against latency for.
pub fn StreamEncoder::write(
  self : StreamEncoder,
  samples : Array[Int64],
) -> Bytes raise EncodeError {
  if samples.length() % self.channels != 0 {
    raise NotWholeFrames(samples.length(), self.channels)
  }
  let out = @buffer.Buffer::Buffer(size_hint=1024)
  let frames = samples.length() / self.channels
  let mut index = 0
  while index < frames {
    let room = BLOCK_SIZE - self.filled
    let remaining = frames - index
    let take = if remaining < room { remaining } else { room }
    for offset = 0; offset < take; offset = offset + 1 {
      for channel = 0; channel < self.channels; channel = channel + 1 {
        self.buffer[(self.filled + offset) * self.channels + channel] = samples[(
            index + offset
          ) *
          self.channels +
          channel]
      }
    }
    self.filled = self.filled + take
    index = index + take
    if self.filled == BLOCK_SIZE {
      let bytes = build_frame(
        self.buffer,
        self.channels - 1,
        self.channels,
        0,
        BLOCK_SIZE,
        self.frame_number,
        self.sample_rate,
        self.bits,
      )
      for byte = 0; byte < bytes.length(); byte = byte + 1 {
        out.write_byte(bytes.at(byte))
      }
      self.frame_number = self.frame_number + 1
      self.filled = 0
    }
  }
  out.to_bytes()
}

///|
/// Flush the final partial block. Call once, after the last
/// [`StreamEncoder::write`]; further calls return nothing.
pub fn StreamEncoder::finish(self : StreamEncoder) -> Bytes {
  let out = @buffer.Buffer::Buffer(size_hint=1024)
  if self.filled > 0 {
    let bytes = build_frame(
      self.buffer,
      self.channels - 1,
      self.channels,
      0,
      self.filled,
      self.frame_number,
      self.sample_rate,
      self.bits,
    )
    for byte = 0; byte < bytes.length(); byte = byte + 1 {
      out.write_byte(bytes.at(byte))
    }
    self.frame_number = self.frame_number + 1
    self.filled = 0
  }
  out.to_bytes()
}
