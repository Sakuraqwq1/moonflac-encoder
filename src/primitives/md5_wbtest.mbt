// moonflac-encoder — pure MoonBit FLAC encoder.

///|
/// Build a byte string from numeric values, so expected digests can be written
/// out without escape sequences.
fn bytes_of(values : Array[Int32]) -> Bytes {
  let out = @buffer.Buffer::Buffer(size_hint=values.length())
  for value in values {
    out.write_byte(value.to_byte())
  }
  out.to_bytes()
}

///|
test "md5 of the empty string" {
  let expected = bytes_of([
    0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, 0xe9, 0x80, 0x09, 0x98, 0xec,
    0xf8, 0x42, 0x7e,
  ])
  assert_eq(md5(b""), expected)
}

///|
test "md5 of abc" {
  let expected = bytes_of([
    0x90, 0x01, 0x50, 0x98, 0x3c, 0xd2, 0x4f, 0xb0, 0xd6, 0x96, 0x3f, 0x7d, 0x28,
    0xe1, 0x7f, 0x72,
  ])
  assert_eq(md5(b"abc"), expected)
}

///|
test "md5 of the reference pangram" {
  let expected = bytes_of([
    0x9e, 0x10, 0x7d, 0x9d, 0x37, 0x2b, 0xb6, 0x82, 0x6b, 0xd8, 0x1d, 0x35, 0x42,
    0xa4, 0x19, 0xd6,
  ])
  assert_eq(md5(b"The quick brown fox jumps over the lazy dog"), expected)
}

///|
test "md5 changes when a byte changes" {
  let a = md5(b"moonflac")
  let b = md5(b"moonflac-encoder")
  assert_true(a != b)
  assert_eq(a, md5(b"moonflac"))
}
