# Changelog

All notable changes to `moonflac-encoder` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-10-22

### Fixed

- **LPC analysis now apodizes the block first.** The plain autocorrelation
  method is ill conditioned for resonant material: a pure tone has
  `1 - a^2 ~ 0.004`, so small estimation errors moved the predictor off the
  true poles and the residual was roughly three times larger than necessary.
  Applying a Hann window before the autocorrelation restores the correct
  coefficients. The measured effect on 4096 frame blocks: mono sine 1,896 to
  1,326 bytes, mono two-tone 3,490 to 1,634 bytes, stereo two-tone 5,363 to
  3,124 bytes.
- **The predictor accumulator is bounded to 32 bits.** A 17 bit side channel
  with 15 bit coefficients and order 12 overflowed, which produced streams that
  32 bit decoders decode differently (libsndfile rejected them). Candidates whose
  measured accumulator exceeds 2^30 are now rejected.

### Added

- **`tools/flacdump.py`**: parses frame and subframe headers and prints the
  coding decision of every subframe (type, LPC order / precision / shift, Rice
  partition order and parameters) plus a bit breakdown. This is what made the
  compression gap diagnosable.
- **LPC gain gate**: LPC is only used when it beats VERBATIM by at least five
  percent, so noise-like blocks fall back to storing the samples.

### Changed

- After these changes 6 of the 10 benchmark signals are smaller than libFLAC's
  default output, the worst case is 3.2% larger, and noise is at parity.

## [0.2.2] - 2026-10-22

### Changed

- Re-published so the README on mooncakes.io matches the repository: the
  benchmark range is now the one `tools/verify.py benchmark` produces
  (12% to 83% above libFLAC) and the test section points at the verification
  script.

## [0.2.1] - 2026-10-22

### Fixed

- The status banner in the README still said LPC and the partition search were
  unimplemented, which contradicted the capability table and the changelog.
  It now states what 0.2.0 actually ships, and a roadmap section lists the
  remaining gaps (streaming, compression parity with libFLAC, adaptive block
  sizes, reference verification for the remaining bit depths).

## [0.2.0] - 2026-10-22

### Added

- **Rice partition search**: partition orders 1–8 are costed per subframe and the
  cheapest is used. The first partition accounts for the warmup samples, as
  RFC 9639 requires. Two tone test blocks shrink by another 1.3% and the cross
  decoder matrix still decodes bit-exactly.

### Changed

- README now carries the CI badge and the measured sizes of the current build.

## [0.1.0] - 2026-10-22

### Added

- **STREAMINFO** with the MD5 signature of the unencoded PCM (RFC 9639 §8.4),
  computed by a from-scratch MD5 implementation.
- **Frames**: fixed blocksize framing, CRC-8 over the frame header, CRC-16 over
  the whole frame, UTF-8 style frame numbers.
- **Subframes**: CONSTANT, VERBATIM, FIXED order 0–4 and LPC order 1–12.
- **LPC**: Levinson-Durbin on the centred autocorrelation, order chosen from the
  residual energy of each recursion step, coefficients quantised to 15 bits with
  a shift chosen to use the available precision.
- **Stereo decorrelation**: left/right, left/side, right/side and mid/side are all
  costed per frame and the cheapest is used.
- **Rice coding**: per partition parameter search including the escape-free
  4-bit parameter form.
- **CLI**: `selftest`, `gen`, `encode`, `md5` and `version` commands over base64
  payloads, so the encoder can be exercised without a file system binding.
- **Tests**: MD5 and CRC reference vectors, STREAMINFO field round trips,
  subframe selection, error paths.
- **Verification**: every build is cross checked against `libsndfile` through
  Python `soundfile` — the decoded samples re-hash to the STREAMINFO digest
  across 16/24 bit, mono/stereo and block boundary cases.
