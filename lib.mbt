// moonflac-encoder — pure MoonBit FLAC encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
/// Encode interleaved signed PCM as a native FLAC stream.
///
/// This is the one entry point most callers need: give it samples already
/// scaled to `bits_per_sample` two's complement range, plus the stream
/// parameters, and it returns a complete `.flac` file.
pub fn encode(
  samples : Array[Int64],
  sample_rate : Int32,
  channels : Int32,
  bits_per_sample : Int32,
) -> Bytes raise @encode.EncodeError {
  @encode.encode(samples, sample_rate, channels, bits_per_sample)
}

///|
/// An incremental encoder for callers that do not hold the whole signal in
/// memory.
pub struct StreamEncoder {
  inner : @encode.StreamEncoder
}

///|
/// Start a streaming encode. Nothing is produced until [`stream_header`].
pub fn stream_encoder(
  sample_rate : Int32,
  channels : Int32,
  bits_per_sample : Int32,
) -> StreamEncoder raise @encode.EncodeError {
  StreamEncoder::{
    inner: @encode.StreamEncoder::new(sample_rate, channels, bits_per_sample),
  }
}

///|
/// The `fLaC` marker plus a STREAMINFO block whose sample count and PCM digest
/// are zero ("unknown", as RFC 9639 allows). Emit it before the first frame.
pub fn stream_header(encoder : StreamEncoder) -> Bytes {
  encoder.inner.header()
}

///|
/// Append interleaved PCM and get back whatever complete frames it produced.
pub fn stream_write(
  encoder : StreamEncoder,
  samples : Array[Int64],
) -> Bytes raise @encode.EncodeError {
  encoder.inner.write(samples)
}

///|
/// Flush the trailing partial block. Call once at the end of the signal.
pub fn stream_finish(encoder : StreamEncoder) -> Bytes {
  encoder.inner.finish()
}

///|
/// Version of the `moonflac-encoder` module.
/// Keep in sync with the `version` field in `moon.mod`.
pub fn version() -> String {
  "0.5.2"
}
