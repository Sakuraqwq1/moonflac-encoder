// moonflac-encoder — pure MoonBit FLAC encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The CLI exists so the encoder can be exercised on any machine without a file
// system binding: payloads travel as base64, the way the surrounding MoonBit
// audio tooling does it.

///|
/// A WAV payload that cannot be turned into integer PCM.
suberror WavError {
  BadContainer(String)
  BadFormat(String)
  UnsupportedFormat(String)
}

///|
fn main {
  let args = @env.args()
  let command = if args.length() > 1 { args[1] } else { "selftest" }
  if command == "selftest" {
    run_selftest()
  } else if command == "gen" {
    run_generate(args)
  } else if command == "md5" {
    let text = if args.length() > 2 { args[2] } else { "" }
    println(hex(@primitives.md5(@utf8.encode(text))))
  } else if command == "version" {
    println(@encoder.version())
  } else if command == "encode" {
    if args.length() < 3 {
      println("usage: moon run cmd/main -- encode <base64 wav | @ENV_NAME>")
      return
    }
    run_encode(resolve_payload(args[2]))
  } else {
    println("unknown command")
    println(
      "  selftest   synthesise a tone, encode it, print the FLAC as base64",
    )
    println("  encode     read a base64 WAV, write the FLAC as base64")
    println("  version    print the module version")
  }
}

///|
/// Accept either a literal base64 string or `@NAME` meaning "read it from the
/// environment", which sidesteps command line length limits.
fn resolve_payload(text : String) -> String {
  if text.length() > 1 && char_code(text, 0) == 0x40 {
    match @env.get_env_var(text[1:].to_owned()) {
      Some(value) => value
      None => ""
    }
  } else {
    text
  }
}

///|
/// Self check: one second of a 440 Hz tone at 44.1 kHz, encoded and printed.
fn run_selftest() -> Unit {
  let rate = 44100
  let frames = 44100
  let samples = Array::make(frames, 0L)
  for index = 0; index < frames; index = index + 1 {
    let time = index.to_double() / rate.to_double()
    let value = 0.5 * @math.sin(6.283185307179586 * 440.0 * time)
    samples[index] = round_half_away(value * 32767.0).to_int64()
  }
  let flac = @encoder.encode(samples, rate, 1, 16) catch {
    (_ : @encode.EncodeError) => {
      println("ERROR: encode failed")
      return
    }
  }
  println("rate=\{rate} channels=1 bits=16 frames=\{frames}")
  println("FLACBEGIN")
  println(@base64.encode(flac[:]))
}

///|
/// Round to the nearest integer, away from zero.
fn round_half_away(value : Double) -> Int32 {
  if value >= 0.0 {
    (value + 0.5).to_int()
  } else {
    (value - 0.5).to_int()
  }
}

///|
/// Decode a base64 WAV payload, encode it as FLAC and print the result.
fn run_encode(payload : String) -> Unit {
  let wav = @base64.decode(payload) catch {
    (_ : @base64.Malformed) => {
      println("ERROR: payload is not valid base64")
      return
    }
  }
  let parsed = parse_wav(wav) catch {
    (_ : WavError) => {
      println("ERROR: unsupported WAV payload")
      return
    }
  }
  let (samples, rate, channels, bits) = parsed
  let flac = @encoder.encode(samples, rate, channels, bits) catch {
    (_ : @encode.EncodeError) => {
      println("ERROR: encode failed")
      return
    }
  }
  println(
    "rate=\{rate} channels=\{channels} bits=\{bits} frames=\{samples.length() / channels}",
  )
  println("FLACBEGIN")
  println(@base64.encode(flac[:]))
}

///|
/// Pull integer PCM out of a RIFF/WAVE payload.
///
/// Only integer PCM is accepted: float WAV would have to be quantised first,
/// which is a lossy policy decision the caller should make, not the CLI.
fn parse_wav(
  data : Bytes,
) -> (Array[Int64], Int32, Int32, Int32) raise WavError {
  if data.length() < 44 {
    raise BadContainer("too short")
  }
  if !matches(data, 0, "RIFF") || !matches(data, 8, "WAVE") {
    raise BadContainer("not RIFF/WAVE")
  }
  let mut format_tag = 0
  let mut channels = 0
  let mut rate = 0
  let mut bits = 0
  let mut payload_start = -1
  let mut payload_length = 0
  let mut position = 12
  while position + 8 <= data.length() {
    let size = u32le(data, position + 4)
    let body = position + 8
    if matches(data, position, "fmt ") {
      if size < 16 {
        raise BadFormat("short fmt chunk")
      }
      format_tag = u16le(data, body)
      channels = u16le(data, body + 2)
      rate = u32le(data, body + 4)
      bits = u16le(data, body + 14)
      if format_tag == 0xFFFE && size >= 40 {
        format_tag = u16le(data, body + 24)
      }
    } else if matches(data, position, "data") {
      payload_start = body
      payload_length = if body + size <= data.length() {
        size
      } else {
        data.length() - body
      }
    }
    position = body + size + size % 2
  }
  if format_tag == 0 {
    raise BadFormat("missing fmt chunk")
  }
  if format_tag != 1 {
    raise UnsupportedFormat("only integer PCM is supported")
  }
  if payload_start < 0 {
    raise BadFormat("missing data chunk")
  }
  if channels < 1 || channels > 8 {
    raise UnsupportedFormat("channel count")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    raise UnsupportedFormat("bit depth")
  }
  let width = bits / 8
  let count = payload_length / width
  let samples = Array::make(count, 0L)
  for index = 0; index < count; index = index + 1 {
    let offset = payload_start + index * width
    samples[index] = read_sample(data, offset, bits)
  }
  (samples, rate, channels, bits)
}

///|
/// Read one little endian sample and sign extend it to Int64.
fn read_sample(data : Bytes, offset : Int32, bits : Int32) -> Int64 {
  if bits == 8 {
    return (data.at(offset).to_int() - 128).to_int64()
  }
  let mut value = 0L
  let width = bits / 8
  for byte = 0; byte < width; byte = byte + 1 {
    value = value |
      ((data.at(offset + byte).to_int().to_int64() & 0xFFL) << (byte * 8))
  }
  if bits == 16 {
    if value >= 0x8000L {
      value = value - 0x10000L
    }
  } else if bits == 24 {
    if value >= 0x800000L {
      value = value - 0x1000000L
    }
  } else if bits == 32 {
    if value >= 0x80000000L {
      value = value - 0x100000000L
    }
  }
  value
}

///|
fn u16le(data : Bytes, offset : Int32) -> Int32 {
  data.at(offset).to_int() | (data.at(offset + 1).to_int() << 8)
}

///|
fn u32le(data : Bytes, offset : Int32) -> Int32 {
  data.at(offset).to_int() |
  (data.at(offset + 1).to_int() << 8) |
  (data.at(offset + 2).to_int() << 16) |
  (data.at(offset + 3).to_int() << 24)
}

///|
/// Compare four bytes at `offset` with an ASCII tag.
fn matches(data : Bytes, offset : Int32, tag : String) -> Bool {
  if offset + 4 > data.length() {
    return false
  }
  for index = 0; index < 4; index = index + 1 {
    if data.at(offset + index).to_int() != char_code(tag, index) {
      return false
    }
  }
  true
}

///|
/// Code point of `index` in `text`, or -1 past the end.
fn char_code(text : String, index : Int32) -> Int32 {
  match text.get_char(index) {
    Some(value) => value.to_int()
    None => -1
  }
}

///|
/// Lower case hex rendering, for the MD5 self check.
fn hex(data : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for index = 0; index < data.length(); index = index + 1 {
    let value = data.at(index).to_int()
    out.write_char(digits.get_char(value >> 4).unwrap())
    out.write_char(digits.get_char(value & 0xF).unwrap())
  }
  out.to_string()
}

///|
/// `gen <rate> <channels> <bits> <frames> <kind>`: synthesise a signal and print
/// the encoded FLAC as base64. Used by the cross decoder test matrix so the
/// payload never has to flow through a command line argument.
fn run_generate(args : Array[String]) -> Unit {
  if args.length() < 7 {
    println("usage: gen <rate> <channels> <bits> <frames> <kind>")
    return
  }
  let rate = int_arg(args[2])
  let channels = int_arg(args[3])
  let bits = int_arg(args[4])
  let frames = int_arg(args[5])
  let kind = int_arg(args[6])
  let scale = (1L << (bits - 1)) - 1L
  let samples = Array::make(frames * channels, 0L)
  for index = 0; index < frames; index = index + 1 {
    for channel = 0; channel < channels; channel = channel + 1 {
      let phase = 1.0 + channel.to_double() * 0.25
      let value = if kind == 0 {
        0.5 *
        @math.sin(
          6.283185307179586 *
          440.0 *
          phase *
          index.to_double() /
          rate.to_double(),
        )
      } else if kind == 1 {
        0.3 *
        @math.sin(
          6.283185307179586 *
          2200.0 *
          phase *
          index.to_double() /
          rate.to_double(),
        ) +
        0.05 *
        @math.sin(
          6.283185307179586 * 97.0 * index.to_double() / rate.to_double(),
        )
      } else if kind == 2 {
        0.0
      } else if kind == 5 {
        0.5 *
        @math.sin(
          6.283185307179586 * 440.0 * index.to_double() / rate.to_double(),
        )
      } else if kind == 3 {
        let wrapped = index % 1000
        wrapped.to_double() / 1000.0 * 2.0 - 1.0
      } else {
        let seed = (index * 1103515245 + channel * 12345 + 12345) % 65536
        seed.to_double() / 65536.0 * 2.0 - 1.0
      }
      samples[index * channels + channel] = round_half_away(
        value * scale.to_double(),
      ).to_int64()
    }
  }
  let flac = @encoder.encode(samples, rate, channels, bits) catch {
    (_ : @encode.EncodeError) => {
      println("ERROR: encode failed")
      return
    }
  }
  println(
    "rate=\{rate} channels=\{channels} bits=\{bits} frames=\{frames} kind=\{kind}",
  )
  println("FLACBEGIN")
  println(@base64.encode(flac[:]))
}

///|
fn int_arg(text : String) -> Int32 {
  @string.parse_int(text) catch {
    (_ : Error) => 0
  }
}
