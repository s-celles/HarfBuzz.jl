# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Bump `HarfBuzz_jll` compat from `8` to `100.14002` (drop the legacy
  8.x line; require the current HarfBuzz release).

### Added

- Initial package scaffold wrapping HarfBuzz via `HarfBuzz_jll`.
- `HbBlob`, `HbFace`, `HbFont`, `HbBuffer` opaque handle types with
  automatic finalizer-based cleanup.
- FreeType-backed font creation (`HbFont(path, size)`) via
  `hb_ft_font_create` so that glyph advances are available.
- `shape!` / `shape` — the core shaping API: takes a font + text and
  returns glyph infos and positions.
- `add_text!`, `clear!`, `guess_segment_properties!` — buffer management.
- `has_glyph`, `get_nominal_glyph` — font glyph availability queries.
- `get_glyph_count` — face glyph count.
- Tests for face/font creation, glyph availability, ASCII/CJK shaping,
  and regional indicator pair shaping.
- GitHub Actions CI (Julia 1.12/1/nightly on Linux/macOS/Windows),
  CompatHelper, TagBot, and Dependabot.
- Documentation via Documenter.jl with API reference.