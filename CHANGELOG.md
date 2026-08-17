# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing has been released yet, so this section describes the package as it
now stands rather than a trail of intermediate API changes.

### Changed

- Support the HarfBuzz 8.x series as well as 100.x:
  `[compat] HarfBuzz_jll = "8.5.1, 100.14002"`. The 100.x-only bound was
  written for `hb_draw_funcs_create`, which 8.5.1 does export; a
  symbol-by-symbol audit of all 158 entry points this package calls
  found exactly one genuinely newer, `hb_font_is_synthetic`.

  The bound was not a local matter. HarfBuzz_jll 100.x is accepted by no
  `Pango_jll` — every one from 1.47 on pins HarfBuzz_jll to 2.x or 8.x —
  so requiring it excluded Pango, hence `libdecor_jll`, hence
  `GLFW_jll` 3.4. Anything needing GLFW 3.4 alongside this package was
  unresolvable, and downstream that surfaced as a segfault rather than a
  resolver error: CImGui's `libcimgui` calls `glfwGetPlatform`, a
  3.4-only symbol, so held at 3.3.9 it called through a null pointer.

### Fixed

- `is_synthetic` works on HarfBuzz 8.x, where `hb_font_is_synthetic`
  does not exist, by computing it from `synthetic_bold` and
  `synthetic_slant`. Not an approximation: upstream's implementation is
  exactly `x_embolden || y_embolden || slant`.
- `deserialize!` accepts the bracketed text form on HarfBuzz 8.x.
  `serialize` emits `[H=0+694|e=1+694]`, which 8.x rejects even though
  it is that library's own output, so a round trip failed there. The
  brackets are now stripped and the string pipe-terminated when the
  loaded library is one that needs it — decided by probe, and applied
  before the call, since `hb_buffer_deserialize_glyphs` appends and a
  rejected parse still leaves partial results behind.

### Added

- Initial package wrapping HarfBuzz via `HarfBuzz_jll`, with the object
  chain `Blob → Face → Font` and finalizer-based cleanup throughout.
- `Blob` from a file path or from a Julia array (without copying), with
  `length`, `data` and `face_count`.
- `Face` with `upem`, `glyph_count`, `face_index`, `table_tags` and
  `reference_table`.
- `Font(face; size, scale, funcs)`, defaulting to `hb_ot_font_set_funcs`:
  HarfBuzz reads the font tables itself, so the package depends only on
  `HarfBuzz_jll`. `scale`/`scale!`, `ppem`/`ppem!`, `ptem`/`ptem!` expose
  the size state, and `px` converts 26.6 fixed point to pixels.
- `FreeType` is a `weakdep` behind one package extension: `funcs =
  :freetype` requires `using FreeType`, and raises an `ArgumentError`
  naming the package to add when it is missing.
- `shape` / `shape!` — the core shaping API — returning glyph infos and
  positions. Both take a `shapers` list, selecting the backend through
  `hb_shape_full`; `shapers()` lists what this build supports.
- Features in three forms: HarfBuzz feature strings (`"kern=0"`,
  `"-liga"`, `"aalt[3:5]=2"`, the canonical and only fully expressive
  one), `"tag" => value` pairs for the common global case, and `Feature`
  values for programmatic construction. `Dict` and `NamedTuple` are not
  accepted — features apply in order and a tag may repeat over different
  ranges, which neither can represent. Unusable forms raise an
  `ArgumentError` listing what is accepted.
- Buffer properties: `direction`, `script`, `language`, `flags`,
  `cluster_level`, `content_type`, `replacement_codepoint`,
  `invisible_glyph`, `not_found_glyph`, and `segment_properties` for the
  three segment properties at once. Enumerations are `Symbol`s at the API
  surface (`:ltr`, `:Arab`, `:monotone_graphemes`).
- Buffer contents: `add_text!` (with `item_offset` / `item_length` so a run
  carries its surrounding context), `add_codepoints!`, `clear!`, `reset!`,
  `reverse_clusters!`, `pre_allocate!`, `allocation_successful`,
  `guess_segment_properties!`, plus `length`, `isempty`, `append!` and
  `reverse!`.
- Reading a buffer directly: `glyph_infos`, `glyph_positions`,
  `codepoints`, `has_positions`.
- Glyph flags on `GlyphInfo`, with `unsafe_to_break`, `unsafe_to_concat`
  and `safe_to_insert_tatweel`. `unsafe_to_break` is what a line breaker
  must consult before splitting a shaped run.
- `serialize`, `deserialize!` and `diff` — the text and JSON formats
  `hb-shape` produces, which make golden tests possible.
- `message_func!`, tracing each shaping stage, equivalent to
  `hb-shape --trace`.
- Font glyph queries: `has_glyph`, `get_nominal_glyph`, `glyph_name`,
  `glyph_from_name`.
- Glyph and font metrics: `glyph_h_advance`, `glyph_v_advance`, the batch
  `glyph_h_advances`, `glyph_extents`, `glyph_h_origin`, `glyph_v_origin`,
  `font_extents`, `glyph_h_kerning`, with `GlyphExtents` and `FontExtents`.
- `unicodes(face)`, the face's `cmap` coverage as a `Set{UInt32}`.
- The `name` table: `name(face, :family)` by symbol or numeric id, and
  `name_entries` to list what a font carries.
- OpenType metrics and style: `metric(font, :x_height)` over all 28 tags,
  and `style(font, :weight)`, which follows any variation set.
- Variable fonts: `has_variations`, `axes`, `named_instances`,
  `set_variations!`, `var_coords_design`, `var_coords_normalized`.
- OpenType layout introspection: `has_substitution`, `has_positioning`,
  `has_glyph_classes`, `layout_script_tags`, `layout_feature_tags`,
  `glyph_class`, `baseline`.
- Font state: `sub_font`, `synthetic_bold`/`synthetic_bold!`,
  `synthetic_slant`/`synthetic_slant!`, `is_synthetic`, `make_immutable!`,
  `is_immutable`.
- Glyph outlines: `outline(font, glyph)` as path commands, and the
  callback form `draw_glyph`, with `PathCommand`.
- Colour fonts: `has_color_palettes`/`_layers`/`_paint`/`_png`/`_svg`,
  `color_palette_count`, `color_palette`, `color_palette_flags`,
  `glyph_color_layers`, `glyph_has_color_paint`, `glyph_color_png`,
  `glyph_color_svg`, with a `Color` struct.
- Math typesetting: `has_math_data`, `math_constant` over all 56 constants,
  `math_italics_correction`, `math_top_accent_attachment`,
  `is_math_extended_shape`, `math_min_connector_overlap`,
  `math_glyph_variants`, `math_glyph_assembly`.
- `subset(face; unicodes, glyphs, flags)`, over `libharfbuzz-subset`.
- HarfBuzz's Unicode data — the tables shaping itself uses: `script_of`,
  `general_category`, `combining_class`, `mirroring`, `compose`,
  `decompose`.
- Library helpers: `version`, `version_string`, `tag`, `tag_string`.
- `ROADMAP.md`: gap analysis against the HarfBuzz C API and the official
  bindings (uharfbuzz, harfbuzz_rs, harfbuzzjs, luaharfbuzz), phased plan,
  and open API design questions.
- Vendored test fonts (`test/fonts/NotoSans-subset.ttf`, 25 KB, and
  `NotoSans-variable-subset.ttf`, 58 KB, both OFL), so
  the suite asserts real shaping behaviour instead of skipping whenever a
  machine lacks a given system font. Kerning, ligatures, `unsafe_to_break`
  and missing coverage are now deterministic. The few tests that still need
  a system font use `@test_skip`, so they show up in the summary instead of
  passing silently. Provenance and the exact subsetting script are in
  `test/fonts/README.md`.
- GitHub Actions CI (Julia 1.12/1/nightly on Linux/macOS/Windows),
  CompatHelper, TagBot, and Dependabot.
- Documentation via Documenter.jl with API reference.

### Changed

- The package resolves no font names. `Font` takes a path to a font file;
  anything else raises an `ArgumentError`. HarfBuzz has no font database
  and neither do the other bindings (uharfbuzz, harfbuzz_rs, harfbuzzjs),
  so matching belongs to Fontconfig.jl, FreeTypeAbstraction.jl or a
  platform API.
- Types carry no `Hb` prefix and nothing is exported: `Font`, `Face`,
  `Buffer`, `Blob` and `Feature` are too generic for a user's namespace.
  Use `import HarfBuzz as HB`.
- `HarfBuzz_jll` compat is `100.14002`, dropping the legacy 8.x line.

### Fixed

These were found by comparing the binding against the JLL headers and by
measurement; each is covered by a regression test.

- `hb_ft_font_create` was called with one argument instead of two, leaving
  the `destroy` callback undefined; `hb_font_destroy` then jumped to a
  garbage pointer. The FreeType path now uses
  `hb_ft_font_create_referenced`, which takes a single argument and manages
  the `FT_Face` lifetime, and fonts are destroyed instead of leaked.
- Glyph positions were read with a 24-byte stride where
  `hb_glyph_position_t` is 20 bytes, so every advance and offset after the
  first glyph was zero. Positions and infos are now decoded through structs
  that mirror the C layout.
- Shaping features were built with an empty range (`start = end = 0`) and
  never applied. They now default to `HB_FEATURE_GLOBAL_START` ..
  `HB_FEATURE_GLOBAL_END`.
- Tag packing indexed characters while measuring bytes; `tag` now calls
  `hb_tag_from_string`.
- One `FT_Library` was created per font and never released; the FreeType
  extension now shares a single library.
- The family-name path ignored the `FT_Set_Char_Size` return code.
- Fonts finalized at process teardown called `FT_Done_Face` after
  `FreeTypeAbstraction`'s `atexit` hook had already destroyed its
  `FT_Library`, segfaulting on exit. Destruction is now skipped once the
  process is shutting down.
