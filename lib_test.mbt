// moonflac-encoder — pure MoonBit FLAC encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
test "public encode facade writes a valid native FLAC stream" {
  let samples = Array::make(4096, 0L)
  for index = 0; index < 4096; index = index + 1 {
    samples[index] = (index * 29 % 2048).to_int64() - 1024L
  }
  let flac = @moonflac-encoder.encode(samples, 44100, 1, 16)
  assert_true(flac.length() > 42)
  assert_eq(flac.at(0).to_int(), 0x66) // 'f'
  assert_eq(flac.at(1).to_int(), 0x4C) // 'L'
  assert_eq(flac.at(2).to_int(), 0x61) // 'a'
  assert_eq(flac.at(3).to_int(), 0x43) // 'C'
}

///|
test "public streaming facade matches one-shot encode frames" {
  let samples = Array::make(4200 * 2, 0L)
  for index = 0; index < samples.length(); index = index + 1 {
    samples[index] = (index * 17 % 512).to_int64() - 256L
  }
  let oneshot = @moonflac-encoder.encode(samples, 44100, 2, 16)
  let encoder = @moonflac-encoder.stream_encoder(44100, 2, 16)
  let header = @moonflac-encoder.stream_header(encoder)
  let body = @moonflac-encoder.stream_write(encoder, samples)
  let tail = @moonflac-encoder.stream_finish(encoder)
  assert_eq(header.length(), 42)
  assert_eq(oneshot.length(), header.length() + body.length() + tail.length())
  for i = 0; i < body.length(); i = i + 1 {
    assert_eq(oneshot.at(42 + i), body.at(i))
  }
  for i = 0; i < tail.length(); i = i + 1 {
    assert_eq(oneshot.at(42 + body.length() + i), tail.at(i))
  }
}

///|
test "public version returns non-empty semver string" {
  let v = @moonflac-encoder.version()
  assert_true(v.length() >= 5)
}
