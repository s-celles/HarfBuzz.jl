# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `hb_ft_font_create` was called with one argument instead of two, leaving
  the `destroy` callback undefined; `hb_font_destroy` then jumped to a
  garbage pointer. `HbFont` now uses `hb_ft_font_create_referenced`, which
  takes a single argument and manages the `FT_Face` lifetime, and fonts are
  destroyed instead of leaked.
- Glyph positions were read with a 24-byte stride where
  `hb_glyph_position_t` is 20 bytes, so every advance and offset after the
  first glyph was zero. Positions and infos are now decoded through structs
  that mirror the C layout.
- Shaping features were built with an empty range (`start = end = 0`) and
  never applied. They now default to `HB_FEATURE_GLOBAL_START` ..
  `HB_FEATURE_GLOBAL_END`.
- `_name_to_tag` indexed characters while measuring bytes; it now indexes
  code units.
- `HbFont` created one `FT_Library` per font and never released it; a single
  library is now created in `__init__`.
- The family-name branch of `HbFont` ignored the `FT_Set_Char_Size` return
  code.
- Fonts finalized at process teardown called `FT_Done_Face` after
  `FreeTypeAbstraction`'s `atexit` hook had already destroyed its
  `FT_Library`, segfaulting on exit. Destruction is now skipped once the
  process is shutting down.

### Changed

- Bump `HarfBuzz_jll` compat from `8` to `100.14002` (drop the legacy
  8.x line; require the current HarfBuzz release).

### Added

- `ROADMAP.md`: gap analysis against the HarfBuzz C API and the official
  bindings (uharfbuzz, harfbuzz_rs, harfbuzzjs, luaharfbuzz), phased plan,
  and open API design questions.
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