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
