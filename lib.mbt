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
/// Version of the `moonflac-encoder` module.
/// Keep in sync with the `version` field in `moon.mod`.
pub fn version() -> String {
  "0.3.0"
}
