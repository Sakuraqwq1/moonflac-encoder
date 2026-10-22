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
  let planes : Array[Array[Int64]] = []
  for channel = 0; channel < channels; channel = channel + 1 {
    let plane = Array::make(count, 0L)
    for index = 0; index < count; index = index + 1 {
      plane[index] = samples[(offset + index) * channels + channel]
    }
    planes.push(plane)
  }
  let mut final_code = channel_code
  let mut payload = planes
  let mut depths = Array::make(channels, bits)
  if channels == 2 {
    let left = planes[0]
    let right = planes[1]
    let side = Array::make(count, 0L)
    let mid = Array::make(count, 0L)
    for index = 0; index < count; index = index + 1 {
      side[index] = left[index] - right[index]
      mid[index] = (left[index] + right[index]) >> 1
    }
    let independent = cost_subframe(left, bits) + cost_subframe(right, bits)
    let left_side = cost_subframe(left, bits) + cost_subframe(side, bits + 1)
    let right_side = cost_subframe(side, bits + 1) + cost_subframe(right, bits)
    let mid_side = cost_subframe(mid, bits) + cost_subframe(side, bits + 1)
    let mut best = independent
    if left_side < best {
      best = left_side
      final_code = 8
      payload = [left, side]
      depths = [bits, bits + 1]
    }
    if right_side < best {
      best = right_side
      final_code = 9
      payload = [side, right]
      depths = [bits + 1, bits]
    }
    if mid_side < best {
      final_code = 10
      payload = [mid, side]
      depths = [bits, bits + 1]
    }
  }
  let (size_code, wide_size) = block_size_code(count)
  let rate_code = sample_rate_code(sample_rate)
  let depth_code = sample_size_code(bits)
  let header = @primitives.BitWriter::new()
  header.write_bits(0x3FFEL, 14)
  header.write_bit(0)
  header.write_bit(0)
  header.write_bits(size_code.to_int64(), 4)
  header.write_bits(rate_code.to_int64(), 4)
  header.write_bits(final_code.to_int64(), 4)
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
  for channel = 0; channel < channels; channel = channel + 1 {
    write_plane_subframe(frame, payload[channel], depths[channel])
  }
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
/// Bit cost of writing one channel, measured by writing it into a scratch
/// writer so the estimate can never drift from what `write_subframe` emits.
fn cost_subframe(plane : Array[Int64], bits : Int32) -> Int64 {
  let scratch = @primitives.BitWriter::new()
  write_plane_subframe(scratch, plane, bits)
  scratch.bit_length()
}

///|
/// Pick the cheapest of CONSTANT, FIXED order 0..4 and VERBATIM for one channel.
///
/// The estimate is exact: each candidate is costed in bits, including the
/// subframe header and the residual partition header, so the choice always
/// shrinks the frame or leaves it as VERBATIM.
fn write_plane_subframe(
  frame : @primitives.BitWriter,
  plane : Array[Int64],
  bits : Int32,
) -> Unit {
  let count = plane.length()
  let first = plane[0]
  let mut index = 1
  let mut constant = true
  while index < count && constant {
    if plane[index] != first {
      constant = false
    }
    index = index + 1
  }
  if constant {
    write_constant(frame, first, bits)
    return
  }
  let mut best_code = 1
  let mut best_bits = (8 + count * bits).to_int64()
  let mut best_shift = 0
  for order = 0; order <= 4; order = order + 1 {
    if order < count {
      let residual = fixed_residual(plane, order)
      let parameter = best_rice_parameter(residual)
      let cost = (8 + order * bits + 6 + 4).to_int64() +
        rice_bits(residual, parameter)
      if cost < best_bits {
        best_bits = cost
        best_code = 8 + order
      }
    }
  }
  let choice = Array::make(4, 0L)
  let coefficients = Array::make(33, 0L)
  let lpc_bits = lpc_search(plane, bits, choice, coefficients)
  if lpc_bits >= 0L && lpc_bits < best_bits {
    best_bits = lpc_bits
    best_code = choice[0].to_int()
    best_shift = choice[2].to_int()
  }
  frame.write_bit(0)
  frame.write_bits(best_code.to_int64(), 6)
  frame.write_bit(0)
  if best_code == 1 {
    for value in plane {
      frame.write_signed(value, bits)
    }
    return
  }
  if best_code < 32 {
    let order = best_code - 8
    for index = 0; index < order; index = index + 1 {
      frame.write_signed(plane[index], bits)
    }
    let residual = fixed_residual(plane, order)
    let partition = best_partition(residual, count, order)
    frame.write_bits(0L, 2)
    frame.write_bits(partition.to_int64(), 4)
    write_partitions(frame, residual, count, order, partition)
    return
  }
  let order = best_code - 32 + 1
  for index = 0; index < order; index = index + 1 {
    frame.write_signed(plane[index], bits)
  }
  frame.write_bits(14L, 4)
  frame.write_signed(best_shift.to_int64(), 5)
  for index = 1; index <= order; index = index + 1 {
    frame.write_signed(coefficients[index], 15)
  }
  let residual = lpc_residual(plane, order, coefficients, best_shift)
  let partition = best_partition(residual, count, order)
  frame.write_bits(0L, 2)
  frame.write_bits(partition.to_int64(), 4)
  write_partitions(frame, residual, count, order, partition)
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
/// Residual of the `order`-th fixed predictor (FLAC coefficients 1, 2 1, 3 3 1,
/// 4 6 4 1).
fn fixed_residual(plane : Array[Int64], order : Int32) -> Array[Int64] {
  let length = plane.length() - order
  let residual = Array::make(length, 0L)
  for index = 0; index < length; index = index + 1 {
    let position = order + index
    let current = plane[position]
    let mut prediction = 0L
    if order == 1 {
      prediction = plane[position - 1]
    } else if order == 2 {
      prediction = 2L * plane[position - 1] - plane[position - 2]
    } else if order == 3 {
      prediction = 3L * plane[position - 1] -
        3L * plane[position - 2] +
        plane[position - 3]
    } else if order == 4 {
      prediction = 4L * plane[position - 1] -
        6L * plane[position - 2] +
        4L * plane[position - 3] -
        plane[position - 4]
    }
    residual[index] = current - prediction
  }
  residual
}

///|
/// Residual of an LPC predictor: `x[n] - ((sum q[k] x[n-k]) >> shift)`.
fn lpc_residual(
  plane : Array[Int64],
  order : Int32,
  coefficients : Array[Int64],
  shift : Int32,
) -> Array[Int64] {
  let length = plane.length() - order
  let residual = Array::make(length, 0L)
  for index = 0; index < length; index = index + 1 {
    let position = order + index
    let mut sum = 0L
    for tap = 1; tap <= order; tap = tap + 1 {
      sum = sum + coefficients[tap] * plane[position - tap]
    }
    residual[index] = plane[position] - (sum >> shift)
  }
  residual
}

///|
/// Quantise one order's prediction coefficients into `out`, returning the right
/// shift the decoder has to apply.
fn quantise_into(
  row : Array[Double],
  precision : Int32,
  out : Array[Int64],
) -> Int32 {
  let order = row.length() - 1
  let ceiling = (1 << (precision - 1)).to_double()
  let mut max_abs = 0.0
  for index = 1; index <= order; index = index + 1 {
    let magnitude = if row[index] < 0.0 { -row[index] } else { row[index] }
    if magnitude > max_abs {
      max_abs = magnitude
    }
  }
  let mut shift = 0
  if max_abs > 0.0 {
    let mut scaled = max_abs
    while scaled * 2.0 < ceiling && shift < 15 {
      scaled = scaled * 2.0
      shift = shift + 1
    }
  }
  let scale = (1 << shift).to_double()
  let high = (1L << (precision - 1)) - 1L
  let low = -(1L << (precision - 1))
  for index = 1; index <= order; index = index + 1 {
    let value = row[index] * scale
    let rounded = if value >= 0.0 {
      (value + 0.5).to_int().to_int64()
    } else {
      (value - 0.5).to_int().to_int64()
    }
    if rounded > high {
      out[index] = high
    } else if rounded < low {
      out[index] = low
    } else {
      out[index] = rounded
    }
  }
  shift
}

///|
/// Search the LPC orders and keep the cheapest one.
///
/// `choice` receives `[code, order, shift, rice parameter]` and `coefficients`
/// receives the quantised taps. Returns the bit cost, or -1 when LPC is not
/// applicable (a block too short to fit a warmup).
fn lpc_search(
  plane : Array[Int64],
  bits : Int32,
  choice : Array[Int64],
  coefficients : Array[Int64],
) -> Int64 {
  let count = plane.length()
  let mut max_order = count - 1
  if max_order > 12 {
    max_order = 12
  }
  if max_order < 1 {
    return -1L
  }
  let mut mean = 0.0
  for value in plane {
    mean = mean + value.to_double()
  }
  mean = mean / count.to_double()
  let ac = Array::make(max_order + 1, 0.0)
  for lag = 0; lag <= max_order; lag = lag + 1 {
    let mut sum = 0.0
    for index = lag; index < count; index = index + 1 {
      sum = sum +
        (plane[index].to_double() - mean) *
        (plane[index - lag].to_double() - mean)
    }
    ac[lag] = sum
  }
  let rows = Array::make(max_order + 1, Array::make(1, 0.0))
  let errors = Array::make(max_order + 1, 0.0)
  let a = Array::make(max_order + 1, 0.0)
  let b = Array::make(max_order + 1, 0.0)
  let mut energy = ac[0]
  errors[0] = energy
  for order = 1; order <= max_order; order = order + 1 {
    let mut acc = ac[order]
    for tap = 1; tap < order; tap = tap + 1 {
      acc = acc + a[tap] * ac[order - tap]
    }
    let reflection = if energy > 0.0 { -acc / energy } else { 0.0 }
    for tap = 1; tap < order; tap = tap + 1 {
      b[tap] = a[tap] + reflection * a[order - tap]
    }
    b[order] = reflection
    for tap = 1; tap <= order; tap = tap + 1 {
      a[tap] = b[tap]
    }
    energy = energy * (1.0 - reflection * reflection)
    let row = Array::make(order + 1, 0.0)
    for tap = 1; tap <= order; tap = tap + 1 {
      row[tap] = -a[tap]
    }
    rows[order] = row
    errors[order] = energy
  }
  let mut candidate = 1
  let mut best_estimate = -1.0
  for order = 1; order <= max_order; order = order + 1 {
    if errors[order] > 0.0 {
      let estimate = count.to_double() * @math.log2(errors[order]) +
        (order * (bits + 15) + 9).to_double()
      if best_estimate < 0.0 || estimate < best_estimate {
        best_estimate = estimate
        candidate = order
      }
    }
  }
  let mut best_bits = -1L
  let scratch = Array::make(33, 0L)
  for delta = -1; delta <= 1; delta = delta + 1 {
    let order = candidate + delta
    if order >= 1 && order <= max_order {
      let shift = quantise_into(rows[order], 15, scratch)
      let residual = lpc_residual(plane, order, scratch, shift)
      let parameter = best_rice_parameter(residual)
      let cost = (8 + order * bits + 4 + 5 + order * 15).to_int64() +
        rice_bits(residual, parameter)
      if best_bits < 0L || cost < best_bits {
        best_bits = cost
        choice[0] = (32 + order - 1).to_int64()
        choice[1] = order.to_int64()
        choice[2] = shift.to_int64()
        choice[3] = parameter.to_int64()
        for tap = 1; tap <= order; tap = tap + 1 {
          coefficients[tap] = scratch[tap]
        }
      }
    }
  }
  best_bits
}

///|
/// Whether partition order `p` is legal for this block.
fn partition_valid(block_size : Int32, order : Int32, p : Int32) -> Bool {
  let parts = 1 << p
  block_size % parts == 0 && block_size >> p > order
}

///|
/// Rice cost of the whole residual split into `2^p` partitions, each with its
/// own parameter.
fn partition_cost(
  residual : Array[Int64],
  block_size : Int32,
  order : Int32,
  p : Int32,
) -> Int64 {
  let parts = 1 << p
  let size = block_size >> p
  let mut offset = 0
  let mut total = 0L
  for index = 0; index < parts; index = index + 1 {
    let length = if index == 0 { size - order } else { size }
    if length > 0 {
      let k = best_parameter_range(residual, offset, length)
      total = total + 4L + rice_bits_range(residual, offset, length, k)
      offset = offset + length
    }
  }
  total
}

///|
/// Pick the partition order that codes the residual in the fewest bits.
fn best_partition(
  residual : Array[Int64],
  block_size : Int32,
  order : Int32,
) -> Int32 {
  let mut best = 0
  let mut best_cost = partition_cost(residual, block_size, order, 0)
  for p = 1; p <= 8; p = p + 1 {
    if partition_valid(block_size, order, p) {
      let cost = partition_cost(residual, block_size, order, p)
      if cost < best_cost {
        best_cost = cost
        best = p
      }
    }
  }
  best
}

///|
/// Rice code one partition.
fn write_rice_range(
  frame : @primitives.BitWriter,
  residual : Array[Int64],
  start : Int32,
  length : Int32,
  k : Int32,
) -> Unit {
  let mask = (1L << k) - 1L
  let end = start + length
  for index = start; index < end; index = index + 1 {
    let folded = zigzag(residual[index])
    frame.write_unary((folded >> k).to_int())
    frame.write_bits(folded & mask, k)
  }
}

///|
/// Write the partition table and the coded residual.
fn write_partitions(
  frame : @primitives.BitWriter,
  residual : Array[Int64],
  block_size : Int32,
  order : Int32,
  p : Int32,
) -> Unit {
  let parts = 1 << p
  let size = block_size >> p
  let mut offset = 0
  for index = 0; index < parts; index = index + 1 {
    let length = if index == 0 { size - order } else { size }
    if length > 0 {
      let k = best_parameter_range(residual, offset, length)
      frame.write_bits(k.to_int64(), 4)
      write_rice_range(frame, residual, offset, length, k)
      offset = offset + length
    }
  }
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
/// Exact cost of Rice coding `length` values of `residual` starting at `start`.
fn rice_bits_range(
  residual : Array[Int64],
  start : Int32,
  length : Int32,
  k : Int32,
) -> Int64 {
  let mut total = 0L
  let end = start + length
  for index = start; index < end; index = index + 1 {
    let folded = zigzag(residual[index])
    total = total + ((folded >> k) + 1L + k.to_int64())
  }
  total
}

///|
/// Exact cost of Rice coding the whole residual.
fn rice_bits(residual : Array[Int64], k : Int32) -> Int64 {
  rice_bits_range(residual, 0, residual.length(), k)
}

///|
/// Pick the Rice parameter that codes `residual` in the fewest bits.
///
/// The mean folded value gives a close estimate, so only three candidates are
/// costed instead of the full 0..14 range.
fn best_rice_parameter(residual : Array[Int64]) -> Int32 {
  best_parameter_range(residual, 0, residual.length())
}

///|
/// Pick the Rice parameter for one partition.
fn best_parameter_range(
  residual : Array[Int64],
  start : Int32,
  length : Int32,
) -> Int32 {
  if length <= 0 {
    return 0
  }
  let mut sum = 0L
  let end = start + length
  for index = start; index < end; index = index + 1 {
    sum = sum + zigzag(residual[index])
  }
  let mean = sum / length.to_int64()
  let mut estimate = 0
  let mut probe = mean
  while probe > 1L {
    probe = probe >> 1
    estimate = estimate + 1
  }
  let base = if estimate > 14 { 14 } else { estimate }
  let mut best_k = 14
  let mut best_bits = rice_bits_range(residual, start, length, 14)
  for delta = -1; delta <= 1; delta = delta + 1 {
    let candidate = base + delta
    if candidate >= 0 && candidate <= 14 {
      let cost = rice_bits_range(residual, start, length, candidate)
      if cost < best_bits {
        best_bits = cost
        best_k = candidate
      }
    }
  }
  best_k
}
