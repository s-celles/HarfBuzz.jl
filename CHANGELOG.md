# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial package scaffold wrapping HarfBuzz via `HarfBuzz_jll`.
- `HbBlob`, `HbFace`, `HbFont`, `HbBuffer` opaque handle types with
  automatic finalizer-based cleanup.
- `shape!` / `shape` — the core shaping API: takes a font + text and
  returns glyph infos and positions.
- `add_text!`, `clear!`, `guess_segment_properties!` — buffer management.
- `has_glyph`, `get_nominal_glyph` — font glyph availability queries.
- `get_glyph_count` — face glyph count.
- Tests for face/font creation, glyph availability, ASCII/CJK shaping,
  and regional indicator pair shaping.