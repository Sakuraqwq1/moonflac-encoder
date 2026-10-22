// moonflac-encoder — pure MoonBit FLAC encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// MD5 (RFC 1321). FLAC stores an MD5 signature of the unencoded PCM in
// STREAMINFO, and decoders verify it, so an encoder without MD5 produces files
// that `flac -t` rejects. The arithmetic is done in Int64 and masked to 32 bits
// after every step, which keeps it portable across backends that differ in
// integer width.

///|
/// The 64 round constants: floor(abs(sin(i + 1)) * 2^32).
fn md5_round_constants() -> Array[Int64] {
  [
    0xd76aa478L, 0xe8c7b756L, 0x242070dbL, 0xc1bdceeeL, 0xf57c0fafL, 0x4787c62aL,
    0xa8304613L, 0xfd469501L, 0x698098d8L, 0x8b44f7afL, 0xffff5bb1L, 0x895cd7beL,
    0x6b901122L, 0xfd987193L, 0xa679438eL, 0x49b40821L, 0xf61e2562L, 0xc040b340L,
    0x265e5a51L, 0xe9b6c7aaL, 0xd62f105dL, 0x02441453L, 0xd8a1e681L, 0xe7d3fbc8L,
    0x21e1cde6L, 0xc33707d6L, 0xf4d50d87L, 0x455a14edL, 0xa9e3e905L, 0xfcefa3f8L,
    0x676f02d9L, 0x8d2a4c8aL, 0xfffa3942L, 0x8771f681L, 0x6d9d6122L, 0xfde5380cL,
    0xa4beea44L, 0x4bdecfa9L, 0xf6bb4b60L, 0xbebfbc70L, 0x289b7ec6L, 0xeaa127faL,
    0xd4ef3085L, 0x04881d05L, 0xd9d4d039L, 0xe6db99e5L, 0x1fa27cf8L, 0xc4ac5665L,
    0xf4292244L, 0x432aff97L, 0xab9423a7L, 0xfc93a039L, 0x655b59c3L, 0x8f0ccc92L,
    0xffeff47dL, 0x85845dd1L, 0x6fa87e4fL, 0xfe2ce6e0L, 0xa3014314L, 0x4e0811a1L,
    0xf7537e82L, 0xbd3af235L, 0x2ad7d2bbL, 0xeb86d391L,
  ]
}

///|
/// Per-round left rotation amounts.
fn md5_shift(round : Int32, index : Int32) -> Int32 {
  let slot = index % 4
  if round == 0 {
    if slot == 0 {
      7
    } else if slot == 1 {
      12
    } else if slot == 2 {
      17
    } else {
      22
    }
  } else if round == 1 {
    if slot == 0 {
      5
    } else if slot == 1 {
      9
    } else if slot == 2 {
      14
    } else {
      20
    }
  } else if round == 2 {
    if slot == 0 {
      4
    } else if slot == 1 {
      11
    } else if slot == 2 {
      16
    } else {
      23
    }
  } else if slot == 0 {
    6
  } else if slot == 1 {
    10
  } else if slot == 2 {
    15
  } else {
    21
  }
}

///|
/// Left rotate a 32 bit value held in an Int64.
fn md5_rotate(value : Int64, amount : Int32) -> Int64 {
  ((value << amount) | (value >> (32 - amount))) & 0xFFFFFFFFL
}

///|
/// Bitwise complement of a 32 bit value (MoonBit has no `~` operator).
fn md5_not(value : Int64) -> Int64 {
  value ^ 0xFFFFFFFFL
}

///|
/// MD5 digest of `data` as 16 raw bytes (little endian words, per RFC 1321).
pub fn md5(data : Bytes) -> Bytes {
  let length = data.length()
  // Message + 0x80 + zero padding + 64 bit length, rounded up to 64 bytes.
  let remainder = (length + 1) % 64
  let zero_pad = if remainder <= 56 { 56 - remainder } else { 120 - remainder }
  let padded_length = length + 1 + zero_pad + 8
  let message = @buffer.Buffer::Buffer(size_hint=padded_length)
  for index = 0; index < length; index = index + 1 {
    message.write_byte(data.at(index))
  }
  message.write_byte(0x80)
  for _pad = 0; _pad < zero_pad; _pad = _pad + 1 {
    message.write_byte(0x00)
  }
  let bit_length = length.to_int64() * 8L
  for index = 0; index < 8; index = index + 1 {
    message.write_byte(((bit_length >> (index * 8)) & 0xFFL).to_byte())
  }
  let bytes = message.to_bytes()
  let mut a = 0x67452301L
  let mut b = 0xefcdab89L
  let mut c = 0x98badcfeL
  let mut d = 0x10325476L
  let constants = md5_round_constants()
  let mut block = 0
  while block * 64 < bytes.length() {
    let base = block * 64
    let words = Array::make(16, 0L)
    for word = 0; word < 16; word = word + 1 {
      let offset = base + word * 4
      words[word] = (bytes.at(offset).to_int().to_int64() & 0xFFL) |
        ((bytes.at(offset + 1).to_int().to_int64() & 0xFFL) << 8) |
        ((bytes.at(offset + 2).to_int().to_int64() & 0xFFL) << 16) |
        ((bytes.at(offset + 3).to_int().to_int64() & 0xFFL) << 24)
    }
    let start_a = a
    let start_b = b
    let start_c = c
    let start_d = d
    for step = 0; step < 64; step = step + 1 {
      let round = step / 16
      let index = step % 16
      let g = if round == 0 {
        index
      } else if round == 1 {
        (5 * step + 1) % 16
      } else if round == 2 {
        (3 * step + 5) % 16
      } else {
        7 * step % 16
      }
      let f = if round == 0 {
        (b & c) | (md5_not(b) & d)
      } else if round == 1 {
        (d & b) | (md5_not(d) & c)
      } else if round == 2 {
        b ^ c ^ d
      } else {
        c ^ (b | md5_not(d))
      }
      let rotated = md5_rotate(
        (a + (f & 0xFFFFFFFFL) + constants[step] + words[g]) & 0xFFFFFFFFL,
        md5_shift(round, index),
      )
      a = d
      d = c
      c = b
      b = (b + rotated) & 0xFFFFFFFFL
    }
    a = (a + start_a) & 0xFFFFFFFFL
    b = (b + start_b) & 0xFFFFFFFFL
    c = (c + start_c) & 0xFFFFFFFFL
    d = (d + start_d) & 0xFFFFFFFFL
    block = block + 1
  }
  let out = @buffer.Buffer::Buffer(size_hint=16)
  for value in [a, b, c, d] {
    for index = 0; index < 4; index = index + 1 {
      out.write_byte(((value >> (index * 8)) & 0xFFL).to_byte())
    }
  }
  out.to_bytes()
}
