// moonflac-encoder — pure MoonBit FLAC encoder.

///|
test "crc8 uses the FLAC frame header polynomial" {
  assert_eq(crc8(b""), 0)
  assert_eq(crc8(b"a"), 0x20)
  assert_eq(crc8(b"123456789"), 0xF4)
  assert_eq(crc8(b"fLaC"), 0x73)
}

///|
test "crc16 uses the FLAC frame footer polynomial" {
  assert_eq(crc16(b""), 0)
  assert_eq(crc16(b"a"), 0x8145)
  assert_eq(crc16(b"123456789"), 0xFEE8)
  assert_eq(crc16(b"fLaC"), 0x3A6D)
}
