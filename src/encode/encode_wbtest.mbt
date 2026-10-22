// moonflac-encoder — pure MoonBit FLAC encoder.

///|
/// Read the STREAMINFO fields back out of an encoded file.
fn streaminfo_of(flac : Bytes) -> (Int32, Int32, Int32, Int32) {
  // "fLaC" (4) + block header (4) then the 34 byte body.
  let body = 8
  let mut rate = 0
  for index = 0; index < 2; index = index + 1 {
    rate = (rate << 8) | flac.at(body + 10 + index).to_int()
  }
  rate = (rate << 4) | (flac.at(body + 12).to_int() >> 4)
  let channels = ((flac.at(body + 12).to_int() >> 1) & 0x7) + 1
  let bits = (
      ((flac.at(body + 12).to_int() & 1) << 4) |
      (flac.at(body + 13).to_int() >> 4)
    ) +
    1
  let mut total = flac.at(body + 13).to_int() & 0xF
  for index = 14; index <= 17; index = index + 1 {
    total = (total << 8) | flac.at(body + index).to_int()
  }
  (rate, channels, bits, total)
}

///|
/// True when `encode` refuses the request.
fn rejects(
  samples : Array[Int64],
  rate : Int32,
  channels : Int32,
  bits : Int32,
) -> Bool {
  let mut rejected = false
  let _ = encode(samples, rate, channels, bits) catch {
    (_ : EncodeError) => {
      rejected = true
      Bytes::make(0, 0)
    }
  }
  rejected
}

///|
test "encode writes a fLaC marker and a 34 byte STREAMINFO" {
  let samples = Array::make(100, 0L)
  for index = 0; index < 100; index = index + 1 {
    samples[index] = (index * 37).to_int64() - 1800L
  }
  let flac = encode(samples, 44100, 1, 16)
  assert_true(flac.length() > 42)
  assert_eq(flac.at(0).to_int(), 0x66) // f
  assert_eq(flac.at(1).to_int(), 0x4C) // L
  assert_eq(flac.at(2).to_int(), 0x61) // a
  assert_eq(flac.at(3).to_int(), 0x43) // C
  // Last metadata block, type 0 (STREAMINFO), 34 bytes long.
  assert_eq(flac.at(4).to_int(), 0x80)
  assert_eq(flac.at(5).to_int(), 0x00)
  assert_eq(flac.at(6).to_int(), 0x00)
  assert_eq(flac.at(7).to_int(), 34)
  let (rate, channels, bits, total) = streaminfo_of(flac)
  assert_eq(rate, 44100)
  assert_eq(channels, 1)
  assert_eq(bits, 16)
  assert_eq(total, 100)
}

///|
test "STREAMINFO carries the MD5 of the unencoded PCM" {
  let samples = Array::make(256, 0L)
  for index = 0; index < 256; index = index + 1 {
    samples[index] = (index % 64).to_int64() - 32L
  }
  let flac = encode(samples, 48000, 1, 16)
  let raw = @buffer.Buffer::Buffer(size_hint=512)
  for index = 0; index < samples.length(); index = index + 1 {
    let value = samples[index]
    raw.write_byte((value & 0xFFL).to_byte())
    raw.write_byte(((value >> 8) & 0xFFL).to_byte())
  }
  let expected = @primitives.md5(raw.to_bytes())
  for index = 0; index < 16; index = index + 1 {
    assert_eq(flac.at(8 + 18 + index), expected.at(index))
  }
}

///|
test "encode rejects malformed requests" {
  assert_true(rejects(Array::make(0, 0L), 44100, 1, 16))
  assert_true(rejects(Array::make(8, 0L), 44100, 0, 16))
  assert_true(rejects(Array::make(8, 0L), 44100, 9, 16))
  assert_true(rejects(Array::make(8, 0L), 44100, 1, 40))
  assert_true(rejects(Array::make(8, 0L), 0, 1, 16))
  assert_true(rejects(Array::make(9, 0L), 44100, 2, 16))
  assert_true(!rejects(Array::make(8, 0L), 44100, 2, 16))
}

///|
test "zigzag maps signed residuals to unsigned ones" {
  assert_eq(zigzag(0L), 0L)
  assert_eq(zigzag(-1L), 1L)
  assert_eq(zigzag(1L), 2L)
  assert_eq(zigzag(-2L), 3L)
  assert_eq(zigzag(2L), 4L)
}

///|
test "a constant signal becomes a tiny subframe" {
  let samples = Array::make(4096, 1234L)
  let flac = encode(samples, 44100, 1, 16)
  // VERBATIM would be over 8 KiB; a CONSTANT subframe is a few dozen bytes.
  assert_true(flac.length() < 200)
}

///|
test "the sample count survives the last short block" {
  let samples = Array::make(4097, 0L)
  let flac = encode(samples, 44100, 1, 16)
  let (_, _, _, total) = streaminfo_of(flac)
  assert_eq(total, 4097)
}
