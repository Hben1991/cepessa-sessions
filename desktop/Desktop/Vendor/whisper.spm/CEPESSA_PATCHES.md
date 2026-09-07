# Vendored whisper.spm

This directory contains the source files needed by Sessions from
[`ggerganov/whisper.spm`](https://github.com/ggerganov/whisper.spm) commit
`a2085436c2eb796af90956b62bd64731f5e5b823` (`1.6.2`). The upstream test
targets and `models/for-tests-ggml-base.en.bin` are intentionally excluded.

Cepessa carries a local Metal packaging patch recovered from the August 4,
2026 Sessions QA work:

- compile `ggml-metal.m` in a separate Objective-C target with manual reference
  counting;
- define `GGML_USE_METAL` for the whisper target;
- use the host application bundle when SwiftPM is the build system; and
- package `ggml-metal.metal` and `ggml-common.h` at the application resource
  root from `desktop/run.sh`.

`LICENSE` is the upstream MIT license. `README.upstream.md` is the upstream
readme from the pinned commit.

Trailing blank lines at end of three upstream Metal/quantization source files
are normalized to one final newline for repository whitespace checks.
