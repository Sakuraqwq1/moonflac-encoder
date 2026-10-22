// moonflac-encoder — pure MoonBit FLAC encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Encoder errors are explicit so callers can tell "your input is unsupported"
// apart from "your input is malformed".

///|
/// Why an encode request was rejected.
pub suberror EncodeError {
  /// No samples were supplied.
  Empty
  /// The channel count is outside the 1..8 range FLAC allows.
  BadChannels(Int32)
  /// The bit depth is outside the 4..32 range FLAC allows.
  BadBits(Int32)
  /// The sample rate is not positive.
  BadSampleRate(Int32)
  /// The sample count is not a multiple of the channel count.
  NotWholeFrames(Int32, Int32)
}

///|
/// Encode interleaved signed PCM as a native FLAC stream.
///
/// `samples` holds `channels` interleaved values per frame, each already scaled
/// to `bits_per_sample` two's complement range. The result is a complete
/// `.flac` file: `fLaC` marker, a STREAMINFO block carrying the PCM digest, and
/// fixed blocksize frames with per-frame CRC-8 and CRC-16.
pub fn encode(
  samples : Array[Int64],
  sample_rate : Int32,
  channels : Int32,
  bits_per_sample : Int32,
) -> Bytes raise EncodeError {
  if channels < 1 || channels > 8 {
    raise BadChannels(channels)
  }
  if bits_per_sample < 4 || bits_per_sample > 32 {
    raise BadBits(bits_per_sample)
  }
  if sample_rate <= 0 {
    raise BadSampleRate(sample_rate)
  }
  let length = samples.length()
  if length == 0 {
    raise Empty
  }
  if length % channels != 0 {
    raise NotWholeFrames(length, channels)
  }
  let total_frames = length / channels
  let block_size = block_size_for(total_frames)
  let frame_count = (total_frames + block_size - 1) / block_size
  let shortest = if frame_count == 1 {
    total_frames
  } else {
    let tail = total_frames % block_size
    if tail == 0 {
      block_size
    } else {
      tail
    }
  }
  let digest = @primitives.md5(raw_pcm(samples, bits_per_sample))
  let out = @buffer.Buffer::Buffer(size_hint=total_frames * channels)
  out.write_string_utf8("fLaC")
  out.write_byte(0x80)
  out.write_byte(0x00)
  out.write_byte(0x00)
  out.write_byte(34)
  let info = @primitives.BitWriter::new()
  info.write_bits(shortest.to_int64(), 16)
  info.write_bits(block_size.to_int64(), 16)
  info.write_bits(0L, 24)
  info.write_bits(0L, 24)
  info.write_bits(sample_rate.to_int64(), 20)
  info.write_bits((channels - 1).to_int64(), 3)
  info.write_bits((bits_per_sample - 1).to_int64(), 5)
  info.write_bits(total_frames.to_int64(), 36)
  let info_bytes = info.finish()
  for index = 0; index < info_bytes.length(); index = index + 1 {
    out.write_byte(info_bytes.at(index))
  }
  for index = 0; index < digest.length(); index = index + 1 {
    out.write_byte(digest.at(index))
  }
  let channel_code = channels - 1
  let mut frame = 0
  let mut offset = 0
  while offset < total_frames {
    let count = if total_frames - offset < block_size {
      total_frames - offset
    } else {
      block_size
    }
    let bytes = build_frame(
      samples, channel_code, channels, offset, count, frame, sample_rate, bits_per_sample,
    )
    for index = 0; index < bytes.length(); index = index + 1 {
      out.write_byte(bytes.at(index))
    }
    offset = offset + count
    frame = frame + 1
  }
  out.to_bytes()
}

///|
/// The block size used for every frame but possibly the last.
///
/// 4096 is the value the reference encoder defaults to and it keeps the frame
/// headers short because it is one of the sizes with a dedicated code.
fn block_size_for(total_frames : Int32) -> Int32 {
  if total_frames < 4096 {
    total_frames
  } else {
    4096
  }
}

///|
/// Serialise `samples` as the byte string FLAC's STREAMINFO digest covers:
/// interleaved, signed, little endian, `ceil(bits/8)` bytes per value.
fn raw_pcm(samples : Array[Int64], bits : Int32) -> Bytes {
  let width = (bits + 7) / 8
  let out = @buffer.Buffer::Buffer(size_hint=samples.length() * width)
  for index = 0; index < samples.length(); index = index + 1 {
    let value = samples[index]
    for byte = 0; byte < width; byte = byte + 1 {
      out.write_byte(((value >> (byte * 8)) & 0xFFL).to_byte())
    }
  }
  out.to_bytes()
}

///|
/// Block size code from the FLAC frame header table, plus the flag that says a
/// 16 bit size field has to follow.
fn block_size_code(count : Int32) -> (Int32, Bool) {
  if count == 192 {
    return (1, false)
  }
  if count == 576 {
    return (2, false)
  }
  if count == 1152 {
    return (3, false)
  }
  if count == 2304 {
    return (4, false)
  }
  if count == 4608 {
    return (5, false)
  }
  let mut power = 256
  let mut code = 8
  while power < 32768 {
    if power == count {
      return (code, false)
    }
    power = power * 2
    code = code + 1
  }
  if count == 32768 {
    return (15, false)
  }
  (7, true)
}

///|
/// Sample rate code from the FLAC frame header table. Zero means "take it from
/// STREAMINFO", which is valid for any rate not listed here.
fn sample_rate_code(rate : Int32) -> Int32 {
  if rate == 88200 {
    1
  } else if rate == 176400 {
    2
  } else if rate == 192000 {
    3
  } else if rate == 8000 {
    4
  } else if rate == 16000 {
    5
  } else if rate == 22050 {
    6
  } else if rate == 24000 {
    7
  } else if rate == 32000 {
    8
  } else if rate == 44100 {
    9
  } else if rate == 48000 {
    10
  } else if rate == 96000 {
    11
  } else {
    0
  }
}

///|
/// Bit depth code from the FLAC frame header table; zero defers to STREAMINFO.
fn sample_size_code(bits : Int32) -> Int32 {
  if bits == 8 {
    1
  } else if bits == 12 {
    2
  } else if bits == 16 {
    4
  } else if bits == 20 {
    5
  } else if bits == 24 {
    6
  } else {
    0
  }
}

///|
/// FLAC's UTF-8 style coding for frame or sample numbers (7 data bits per byte).
fn write_utf8_number(writer : @primitives.BitWriter, value : Int64) -> Unit {
  let (length, prefix) = if value < 0x80L {
    (1, 0x00)
  } else if value < 0x800L {
    (2, 0xC0)
  } else if value < 0x10000L {
    (3, 0xE0)
  } else if value < 0x200000L {
    (4, 0xF0)
  } else if value < 0x4000000L {
    (5, 0xF8)
  } else if value < 0x80000000L {
    (6, 0xFC)
  } else {
    (7, 0xFE)
  }
  let mut remaining = value
  let bytes = Array::make(length, 0)
  let mut index = length - 1
  while index > 0 {
    bytes[index] = 0x80 | (remaining & 0x3F).to_int()
    remaining = remaining >> 6
    index = index - 1
  }
  bytes[0] = prefix | remaining.to_int()
  for byte in bytes {
    writer.write_bits(byte.to_int64(), 8)
  }
}

///|
/// Assemble one frame: header with CRC-8, the subframes, and the CRC-16 footer.
fn build_frame(
  samples : Array[Int64],
  channel_code : Int32,
  channels : Int32,
  offset : Int32,
  count : Int32,
  number : Int32,
  sample_rate : Int32,
  bits : Int32,
) -> Bytes {
  let (size_code, wide_size) = block_size_code(count)
  let rate_code = sample_rate_code(sample_rate)
  let depth_code = sample_size_code(bits)
  let header = @primitives.BitWriter::new()
  header.write_bits(0x3FFEL, 14)
  header.write_bit(0)
  header.write_bit(0)
  header.write_bits(size_code.to_int64(), 4)
  header.write_bits(rate_code.to_int64(), 4)
  header.write_bits(channel_code.to_int64(), 4)
  header.write_bits(depth_code.to_int64(), 3)
  header.write_bit(0)
  write_utf8_number(header, number.to_int64())
  if wide_size {
    header.write_bits((count - 1).to_int64(), 16)
  }
  if rate_code == 12 {
    header.write_bits((sample_rate / 1000).to_int64(), 8)
  } else if rate_code == 13 {
    header.write_bits(sample_rate.to_int64(), 16)
  } else if rate_code == 14 {
    header.write_bits((sample_rate / 10).to_int64(), 16)
  }
  let header_bytes = header.finish()
  let frame = @primitives.BitWriter::new()
  frame.write_bytes(header_bytes)
  frame.write_bits(@primitives.crc8(header_bytes).to_int64(), 8)
  write_subframes(frame, samples, channels, offset, count, bits)
  let body = frame.finish()
  let checksum = @primitives.crc16(body)
  let out = @buffer.Buffer::Buffer(size_hint=body.length() + 2)
  for index = 0; index < body.length(); index = index + 1 {
    out.write_byte(body.at(index))
  }
  out.write_byte(((checksum >> 8) & 0xFF).to_byte())
  out.write_byte((checksum & 0xFF).to_byte())
  out.to_bytes()
}

///|
/// Write one subframe per channel, choosing the cheapest coding for each.
fn write_subframes(
  frame : @primitives.BitWriter,
  samples : Array[Int64],
  channels : Int32,
  offset : Int32,
  count : Int32,
  bits : Int32,
) -> Unit {
  for channel = 0; channel < channels; channel = channel + 1 {
    write_subframe(frame, samples, channels, channel, offset, count, bits)
  }
}

///|
/// Pick the cheapest of CONSTANT, FIXED order 0..4 and VERBATIM for one channel.
///
/// The estimate is exact: each candidate is costed in bits, including the
/// subframe header and the residual partition header, so the choice always
/// shrinks the frame or leaves it as VERBATIM.
fn write_subframe(
  frame : @primitives.BitWriter,
  samples : Array[Int64],
  channels : Int32,
  channel : Int32,
  offset : Int32,
  count : Int32,
  bits : Int32,
) -> Unit {
  let first = samples[offset * channels + channel]
  let mut index = 1
  let mut constant = true
  while index < count && constant {
    if samples[(offset + index) * channels + channel] != first {
      constant = false
    }
    index = index + 1
  }
  if constant {
    write_constant(frame, first, bits)
    return
  }
  let mut best_bits = (8 + count * bits).to_int64()
  let mut best_order = -1
  let mut best_k = 0
  for order = 0; order <= 4; order = order + 1 {
    if order < count {
      let residual = fixed_residual(
        samples, channels, channel, offset, count, order,
      )
      let parameter = best_rice_parameter(residual)
      let cost = (8 + order * bits + 6 + 4).to_int64() +
        rice_bits(residual, parameter)
      if cost < best_bits {
        best_bits = cost
        best_order = order
        best_k = parameter
      }
    }
  }
  if best_order >= 0 {
    write_fixed(
      frame, samples, channels, channel, offset, count, bits, best_order, best_k,
    )
  } else {
    write_verbatim(frame, samples, channels, channel, offset, count, bits)
  }
}

///|
/// CONSTANT subframe: every sample has the same value.
fn write_constant(
  frame : @primitives.BitWriter,
  value : Int64,
  bits : Int32,
) -> Unit {
  frame.write_bit(0)
  frame.write_bits(0L, 6)
  frame.write_bit(0)
  frame.write_signed(value, bits)
}

///|
/// VERBATIM subframe: every sample stored at its full width.
fn write_verbatim(
  frame : @primitives.BitWriter,
  samples : Array[Int64],
  channels : Int32,
  channel : Int32,
  offset : Int32,
  count : Int32,
  bits : Int32,
) -> Unit {
  frame.write_bit(0)
  frame.write_bits(1L, 6)
  frame.write_bit(0)
  for index = 0; index < count; index = index + 1 {
    frame.write_signed(samples[(offset + index) * channels + channel], bits)
  }
}

///|
/// FIXED subframe: `order` warmup samples, then Rice coded residuals.
fn write_fixed(
  frame : @primitives.BitWriter,
  samples : Array[Int64],
  channels : Int32,
  channel : Int32,
  offset : Int32,
  count : Int32,
  bits : Int32,
  order : Int32,
  parameter : Int32,
) -> Unit {
  frame.write_bit(0)
  frame.write_bits((8 + order).to_int64(), 6)
  frame.write_bit(0)
  for index = 0; index < order; index = index + 1 {
    frame.write_signed(samples[(offset + index) * channels + channel], bits)
  }
  let residual = fixed_residual(
    samples, channels, channel, offset, count, order,
  )
  frame.write_bits(0L, 2)
  frame.write_bits(0L, 4)
  frame.write_bits(parameter.to_int64(), 4)
  for value in residual {
    let folded = zigzag(value)
    frame.write_unary((folded >> parameter).to_int())
    frame.write_bits(folded & ((1L << parameter) - 1L), parameter)
  }
}

///|
/// Residual of the `order`-th fixed predictor (FLAC coefficients 1, 2 1, 3 3 1,
/// 4 6 4 1).
fn fixed_residual(
  samples : Array[Int64],
  channels : Int32,
  channel : Int32,
  offset : Int32,
  count : Int32,
  order : Int32,
) -> Array[Int64] {
  let length = count - order
  let residual = Array::make(length, 0L)
  for index = 0; index < length; index = index + 1 {
    let position = offset + order + index
    let current = samples[position * channels + channel]
    let mut prediction = 0L
    if order >= 1 {
      prediction = prediction + samples[(position - 1) * channels + channel]
    }
    if order >= 2 {
      prediction = 2L * prediction -
        samples[(position - 2) * channels + channel]
    }
    if order >= 3 {
      prediction = 3L * samples[(position - 1) * channels + channel] -
        3L * samples[(position - 2) * channels + channel] +
        samples[(position - 3) * channels + channel]
    }
    if order >= 4 {
      prediction = 4L * samples[(position - 1) * channels + channel] -
        6L * samples[(position - 2) * channels + channel] +
        4L * samples[(position - 3) * channels + channel] -
        samples[(position - 4) * channels + channel]
    }
    residual[index] = current - prediction
  }
  residual
}

///|
/// Fold a signed residual into an unsigned one (FLAC's zig-zag rule).
fn zigzag(value : Int64) -> Int64 {
  if value >= 0L {
    value << 1
  } else {
    (-value << 1) - 1L
  }
}

///|
/// Exact cost of Rice coding `residual` with parameter `k`.
fn rice_bits(residual : Array[Int64], k : Int32) -> Int64 {
  let mut total = 0L
  for value in residual {
    let folded = zigzag(value)
    total = total + ((folded >> k) + 1L + k.to_int64())
  }
  total
}

///|
/// Pick the Rice parameter that codes `residual` in the fewest bits.
///
/// The mean folded value gives a close estimate, so only three candidates are
/// costed instead of the full 0..14 range.
fn best_rice_parameter(residual : Array[Int64]) -> Int32 {
  let length = residual.length()
  if length == 0 {
    return 0
  }
  let mut sum = 0L
  for value in residual {
    sum = sum + zigzag(value)
  }
  let mean = sum / length.to_int64()
  let mut estimate = 0
  let mut probe = mean
  while probe > 1L {
    probe = probe >> 1
    estimate = estimate + 1
  }
  let mut best_k = 0
  let mut best_bits = rice_bits(residual, 0)
  for delta = -1; delta <= 1; delta = delta + 1 {
    let candidate = estimate + delta
    if candidate >= 0 && candidate <= 14 {
      let cost = rice_bits(residual, candidate)
      if cost < best_bits {
        best_bits = cost
        best_k = candidate
      }
    }
  }
  best_k
}
