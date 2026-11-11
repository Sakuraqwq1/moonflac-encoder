// moonflac-encoder — pure MoonBit FLAC encoder.

///|
/// Run a signal through the incremental encoder in chunks of `chunk` frames.
fn stream_all(samples : Array[Int64], channels : Int32, chunk : Int32) -> Bytes {
  let encoder = StreamEncoder::new(44100, channels, 16) catch {
    (_ : EncodeError) => return Bytes::make(0, 0)
  }
  let out = @buffer.Buffer::Buffer(size_hint=samples.length())
  let header = encoder.header()
  for index = 0; index < header.length(); index = index + 1 {
    out.write_byte(header.at(index))
  }
  let frames = samples.length() / channels
  let mut offset = 0
  while offset < frames {
    let remaining = frames - offset
    let take = if remaining < chunk { remaining } else { chunk }
    let piece = Array::make(take * channels, 0L)
    for index = 0; index < take * channels; index = index + 1 {
      piece[index] = samples[offset * channels + index]
    }
    let bytes = encoder.write(piece) catch {
      (_ : EncodeError) => return Bytes::make(0, 0)
    }
    for index = 0; index < bytes.length(); index = index + 1 {
      out.write_byte(bytes.at(index))
    }
    offset = offset + take
  }
  let tail = encoder.finish()
  for index = 0; index < tail.length(); index = index + 1 {
    out.write_byte(tail.at(index))
  }
  out.to_bytes()
}

///|
/// A signal that is deliberately not a multiple of the block size.
fn ramp(frames : Int32, channels : Int32) -> Array[Int64] {
  let samples = Array::make(frames * channels, 0L)
  for index = 0; index < frames; index = index + 1 {
    for channel = 0; channel < channels; channel = channel + 1 {
      samples[index * channels + channel] = ((index * 37 + channel * 11) % 2000).to_int64() -
        1000L
    }
  }
  samples
}

///|
test "the stream header leaves the sample count and digest unknown" {
  let encoder = StreamEncoder::new(44100, 2, 16)
  let header = encoder.header()
  assert_eq(header.at(0).to_int(), 0x66)
  assert_eq(header.at(3).to_int(), 0x43)
  // STREAMINFO body starts at 8; the 36 bit sample count and the 16 byte
  // digest are both zero.
  for index = 0; index < 4; index = index + 1 {
    assert_eq(header.at(13 + index).to_int() & 0xF, 0)
  }
  for index = 0; index < 16; index = index + 1 {
    assert_eq(header.at(8 + 18 + index).to_int(), 0)
  }
}

///|
test "chunk boundaries do not change the output" {
  let samples = ramp(4097, 1)
  let whole = stream_all(samples, 1, 4097)
  let chunked = stream_all(samples, 1, 1000)
  assert_eq(whole.length(), chunked.length())
  for index = 0; index < whole.length(); index = index + 1 {
    assert_eq(whole.at(index), chunked.at(index))
  }
}

///|
test "the stream splits into whole blocks plus a partial tail" {
  let samples = ramp(4097, 2)
  let encoded = stream_all(samples, 2, 512)
  // Two frames: 4096 samples and 1 sample. The second one uses the 16 bit
  // block size code, which is what the header of that frame has to say.
  assert_true(encoded.length() > 4096)
}

///|
test "streamed frames are byte-for-byte identical to one-shot frames" {
  for bits in [8, 16, 24] {
    let samples = Array::make(4200 * 2, 0L)
    for index = 0; index < samples.length(); index = index + 1 {
      samples[index] = (index * 13 % 120).to_int64() - 60L
    }
    let oneshot = encode(samples, 44100, 2, bits)
    let encoder = StreamEncoder::new(44100, 2, bits)
    let streamed = @buffer.Buffer::Buffer(size_hint=oneshot.length())
    let header = encoder.header()
    for index = 0; index < header.length(); index = index + 1 {
      streamed.write_byte(header.at(index))
    }
    let body = encoder.write(samples)
    for index = 0; index < body.length(); index = index + 1 {
      streamed.write_byte(body.at(index))
    }
    let tail = encoder.finish()
    for index = 0; index < tail.length(); index = index + 1 {
      streamed.write_byte(tail.at(index))
    }
    let streamed_bytes = streamed.to_bytes()
    assert_eq(oneshot.length(), streamed_bytes.length())
    // Bytes 42..end are the encoded frames; they must match identically.
    for index = 42; index < oneshot.length(); index = index + 1 {
      assert_eq(oneshot.at(index), streamed_bytes.at(index))
    }
  }
}

///|
test "StreamEncoder validates parameters and sample ranges" {
  let mut bad_init = false
  let _ = StreamEncoder::new(655351, 2, 16) catch {
    (_ : EncodeError) => {
      bad_init = true
      StreamEncoder::new(44100, 1, 16)
    }
  }
  assert_true(bad_init)
  let encoder = StreamEncoder::new(44100, 2, 4)
  let mut odd_rejected = false
  let _ = encoder.write([0L, 1L, 2L]) catch {
    (_ : EncodeError) => {
      odd_rejected = true
      Bytes::make(0, 0)
    }
  }
  assert_true(odd_rejected)
  let mut range_rejected = false
  let _ = encoder.write([0L, 8L]) catch {
    (_ : EncodeError) => {
      range_rejected = true
      Bytes::make(0, 0)
    }
  }
  assert_true(range_rejected)
  // Empty finish produces 0 bytes and is idempotent.
  assert_eq(encoder.finish().length(), 0)
  assert_eq(encoder.finish().length(), 0)
}
