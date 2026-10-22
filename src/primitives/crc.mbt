// moonflac-encoder — pure MoonBit FLAC encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
/// CRC-8 over `data`, using the FLAC frame-header polynomial
/// `x^8 + x^2 + x + 1` (0x07) with a zero initial value.
pub fn crc8(data : Bytes) -> Int32 {
  let mut crc = 0
  for index = 0; index < data.length(); index = index + 1 {
    crc = crc ^ (data.at(index).to_int() & 0xFF)
    for _bit = 0; _bit < 8; _bit = _bit + 1 {
      if (crc & 0x80) != 0 {
        crc = ((crc << 1) ^ 0x07) & 0xFF
      } else {
        crc = (crc << 1) & 0xFF
      }
    }
  }
  crc
}

///|
/// CRC-16 over `data`, using the FLAC frame-footer polynomial
/// `x^16 + x^15 + x^2 + 1` (0x8005) with a zero initial value.
pub fn crc16(data : Bytes) -> Int32 {
  let mut crc = 0
  for index = 0; index < data.length(); index = index + 1 {
    crc = crc ^ ((data.at(index).to_int() & 0xFF) << 8)
    for _bit = 0; _bit < 8; _bit = _bit + 1 {
      if (crc & 0x8000) != 0 {
        crc = ((crc << 1) ^ 0x8005) & 0xFFFF
      } else {
        crc = (crc << 1) & 0xFFFF
      }
    }
  }
  crc
}
