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
let md5_round_constants : Array[Int64] = [
  0xd76aa478L, 0xe8c7b756L, 0x242070dbL, 0xc1bdceeeL, 0xf57c0fafL, 0x4787c62aL, 0xa8304613L,
  0xfd469501L, 0x698098d8L, 0x8b44f7afL, 0xffff5bb1L, 0x895cd7beL, 0x6b901122L, 0xfd987193L,
  0xa679438eL, 0x49b40821L, 0xf61e2562L, 0xc040b340L, 0x265e5a51L, 0xe9b6c7aaL, 0xd62f105dL,
  0x02441453L, 0xd8a1e681L, 0xe7d3fbc8L, 0x21e1cde6L, 0xc33707d6L, 0xf4d50d87L, 0x455a14edL,
  0xa9e3e905L, 0xfcefa3f8L, 0x676f02d9L, 0x8d2a4c8aL, 0xfffa3942L, 0x8771f681L, 0x6d9d6122L,
  0xfde5380cL, 0xa4beea44L, 0x4bdecfa9L, 0xf6bb4b60L, 0xbebfbc70L, 0x289b7ec6L, 0xeaa127faL,
  0xd4ef3085L, 0x04881d05L, 0xd9d4d039L, 0xe6db99e5L, 0x1fa27cf8L, 0xc4ac5665L, 0xf4292244L,
  0x432aff97L, 0xab9423a7L, 0xfc93a039L, 0x655b59c3L, 0x8f0ccc92L, 0xffeff47dL, 0x85845dd1L,
  0x6fa87e4fL, 0xfe2ce6e0L, 0xa3014314L, 0x4e0811a1L, 0xf7537e82L, 0xbd3af235L, 0x2ad7d2bbL,
  0xeb86d391L,
]

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
/// Incremental PCM digest with a single 64-byte block of pending input.
pub struct Md5 {
  mut a : Int64
  mut b : Int64
  mut c : Int64
  mut d : Int64
  mut length : Int64
  words : Array[Int64]
}

///|
pub fn Md5::new() -> Md5 {
  {
    a: 0x67452301L,
    b: 0xefcdab89L,
    c: 0x98badcfeL,
    d: 0x10325476L,
    length: 0L,
    words: Array::make(16, 0L),
  }
}

///|
fn Md5::compress(self : Md5) -> Unit {
  let words = self.words
  let constants = md5_round_constants
  let mut a = self.a
  let mut b = self.b
  let mut c = self.c
  let mut d = self.d
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
  self.a = (a + self.a) & 0xFFFFFFFFL
  self.b = (b + self.b) & 0xFFFFFFFFL
  self.c = (c + self.c) & 0xFFFFFFFFL
  self.d = (d + self.d) & 0xFFFFFFFFL
  self.words.fill(0L)
}

///|
fn Md5::push(self : Md5, byte : Byte) -> Unit {
  let offset = (self.length & 63L).to_int()
  let word = offset / 4
  self.words[word] = self.words[word] |
    (byte.to_int().to_int64() << (8 * (offset % 4)))
  self.length += 1L
  if offset == 63 {
    self.compress()
  }
}

///|
pub fn Md5::update(self : Md5, data : Bytes) -> Unit {
  for index = 0; index < data.length(); index = index + 1 {
    self.push(data[index])
  }
}

///|
pub fn Md5::digest(self : Md5) -> Bytes {
  let state = { ..self, words: self.words.copy(), }
  let bits = self.length * 8L
  state.push(0x80)
  while state.length % 64L != 56L {
    state.push(0x00)
  }
  for index = 0; index < 8; index = index + 1 {
    state.push(((bits >> (index * 8)) & 0xFFL).to_byte())
  }
  let out = @buffer.Buffer::Buffer()
  for value in [state.a, state.b, state.c, state.d] {
    for index = 0; index < 4; index = index + 1 {
      out.write_byte(((value >> (index * 8)) & 0xFFL).to_byte())
    }
  }
  out.to_bytes()
}

///|
/// MD5 digest of data as 16 raw bytes (RFC 1321).
pub fn md5(data : Bytes) -> Bytes {
  let state = Md5::new()
  state.update(data)
  state.digest()
}
