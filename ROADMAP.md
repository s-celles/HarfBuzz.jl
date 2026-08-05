# Roadmap

This document tracks where `HarfBuzz.jl` stands against the HarfBuzz C API
and the other language bindings maintained under the
[harfbuzz organisation](https://github.com/harfbuzz/), what is planned, and
which design questions are still open.

Reference points used for the gap analysis:

- The C API reference: <https://harfbuzz.github.io/>
- The headers shipped by the pinned `HarfBuzz_jll` artifact
- [`uharfbuzz`](https://github.com/harfbuzz/uharfbuzz) (Python, official)
- [`harfbuzz_rs`](https://github.com/harfbuzz/harfbuzz_rs) (Rust, official)
- [`harfbuzzjs`](https://github.com/harfbuzz/harfbuzzjs) (JavaScript/WASM)
- [`luaharfbuzz`](https://github.com/harfbuzz/luaharfbuzz) (Lua)

## Status

`HarfBuzz.jl` currently binds **10 of the 508 `hb_*` symbols** exported by
`libharfbuzz` in the JLL. `libharfbuzz-subset` and `libharfbuzz-gobject` ship
in the same artifact and are unused.

The package covers exactly one path: open a FreeType face, wrap it, shape a
UTF-8 string, read glyph ids and clusters back. That path is enough for the
original motivation (shaping text before handing glyphs to ImGui), but it is
narrow compared to every other binding, and three defects listed below make
parts of it silently incorrect.

## Phase 0 — Correctness (blocking)

Three defects were confirmed against the JLL headers and by measurement.
Each needs a failing test first, then the fix.

### 0.1 `hb_ft_font_create` is called with one argument instead of two

`src/HarfBuzz.jl` calls

```julia
ccall((:hb_ft_font_create, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), ft_face)
```

but the C signature is

```c
hb_font_t *hb_ft_font_create (FT_Face ft_face, hb_destroy_func_t destroy);
```

The `destroy` argument is therefore whatever the second argument register
happens to hold. `hb_font_destroy` later calls it as a function pointer,
which is what actually crashes on macOS ARM64 — not a FreeType.jl struct
layout mismatch, as the comment in `_hb_font_destroy` currently claims.

**Fix:** use `hb_ft_font_create_referenced(FT_Face)`, which takes a single
argument and manages the `FT_Face` lifetime itself (`FT_Reference_Face` /
`FT_Done_Face`). The deliberate leak in `_hb_font_destroy` can then be
removed and `hb_font_destroy` called normally.

### 0.2 `_HB_GLYPH_POS_SIZE` is 24; `hb_glyph_position_t` is 20 bytes

`hb_glyph_position_t` is four `hb_position_t` plus one `hb_var_int_t`, i.e.
20 bytes. With a stride of 24 every glyph after the first is read at the
wrong offset. Measured with Menlo at 18px, `"Hello"`:

```
stride=20  x_advance = [694, 694, 694, 694, 694]   correct
stride=24  x_advance = [694,   0,   0,   0,   0]   current code
```

This — not a FreeType integration problem — is the cause of the "glyph
advances may be zero" caveat in the `shape` docstring. That caveat should be
deleted along with the bug.

**Fix:** stop decoding by hand-computed offsets. Declare isbits structs that
mirror the C layout and let Julia compute the stride:

```julia
struct HbGlyphInfoRaw
    codepoint::UInt32; mask::UInt32; cluster::UInt32; var1::UInt32; var2::UInt32
end
struct HbGlyphPosRaw
    x_advance::Int32; y_advance::Int32; x_offset::Int32; y_offset::Int32; var::UInt32
end
infos = unsafe_wrap(Array, convert(Ptr{HbGlyphInfoRaw}, info_ptr), n)
```

This also gives a zero-copy view of the buffer instead of two element-wise
copies.

### 0.3 Shaping features are silently ignored

Features are built as `(tag, value, 0, 0)`. `start = 0, end = 0` is an empty
range. HarfBuzz uses `HB_FEATURE_GLOBAL_START = 0` and
`HB_FEATURE_GLOBAL_END = (unsigned) -1` to mean "whole buffer". Measured with
Times New Roman, `"AVAWTo"`, `kern=0`:

```
default              [758, 684, 712, 1041, 664, 536]
kern=0, end=0        [758, 684, 712, 1041, 664, 536]   no effect
kern=0, end=typemax  [832, 832, 832, 1087, 704, 576]   applied
```

**Fix:** default `end` to `typemax(UInt32)`, and expose the range so a
feature can be applied to a sub-range of the buffer.

### 0.4 Smaller correctness items

- `_name_to_tag` mixes `sizeof(s)` (bytes) with `s[i]` (character indexing)
  and does not validate length. `hb_tag_from_string` already exists.
- The family-name branch of `HbFont` calls `FT_Set_Char_Size` on the object
  returned by `FreeTypeAbstraction.findfont`, which is **cached and shared**;
  this mutates global state seen by other users of FreeTypeAbstraction. The
  return code is also ignored.
- `add_text!` does not expose `item_offset` / `item_length`, so no context
  can be supplied around the shaped run (needed for correct contextual forms
  at run boundaries, e.g. Arabic).
- `hb_buffer_allocation_successful` is never checked.

## Phase 1 — Object model

The structural gap: there is no `Blob` and no `Face`. Every other binding
exposes the `Blob → Face → Font` chain, and HarfBuzz can supply glyph
metrics itself through `hb_ot_font_set_funcs` — **FreeType is optional**.

Today FreeType and FreeTypeAbstraction are hard dependencies, which means a
font cannot be loaded from bytes in memory, tables cannot be reached,
variable-font instances cannot be driven properly, and the dependency
footprint is larger than it needs to be.

- `HbBlob`: `hb_blob_create`, `hb_blob_create_from_file`, data access, length
- `HbFace`: `hb_face_create(blob, index)`, `face_count`, `upem`,
  `glyph_count`, `reference_table`, `table_tags`, `unicodes`
- `HbFont(face)` with `hb_ot_font_set_funcs` — no FreeType involved
- `hb_font_set_scale` / `ppem` / `ptem`, synthetic bold and slant, sub-fonts,
  immutability
- Move `FreeType` and `FreeTypeAbstraction` to `weakdeps` behind a package
  extension, so the base package depends only on `HarfBuzz_jll`

## Phase 2 — Buffer API

- Properties: `direction`, `script`, `language`, `flags`, `cluster_level`,
  `content_type`, `invisible_glyph`, `not_found_glyph`,
  `replacement_codepoint`, `segment_properties`
- Input: `hb_buffer_add`, `add_codepoints`, `add_utf16`, `add_utf32`,
  `add_latin1`, `append`, plus `item_offset`/`item_length` context
- Manipulation: `reset`, `reverse`, `reverse_clusters`, `length`,
  `pre_allocate`, `diff`
- `hb_buffer_serialize_glyphs` / `deserialize_glyphs` (text and JSON) —
  the basis for golden tests comparable to the `hb-shape` CLI
- `hb_buffer_set_message_func` for tracing shaping steps
- `hb_glyph_info_get_glyph_flags` — `UNSAFE_TO_BREAK` and
  `UNSAFE_TO_CONCAT` are required for correct line breaking, which is
  directly relevant to the ImGui use case
- Common types: `hb_direction_t`, `hb_script_t`, `hb_language_t`,
  `hb_tag_t` ↔ string, `hb_version_string`
- `hb_shape_full` (shaper list), `hb_shape_list_shapers`,
  `hb_feature_from_string` / `hb_feature_to_string` (`"liga=0"`, `"+kern"`)

## Phase 3 — Font and face queries

- Glyph metrics: `glyph_h/v_advance` (single and batch), `glyph_extents`,
  `glyph_h/v_origin`, `h/v_extents`, `glyph_h_kerning`
- Glyph names: `glyph_to_string`, `glyph_from_string`, `get_glyph_name`,
  `get_glyph_from_name`
- Variable fonts: `hb_ot_var_get_axis_infos`, named instances,
  `set_variation(s)`, design and normalised coordinates
- `hb-ot-name`: family, style, licence, and other name records
- `hb-ot-metrics`: x-height, cap-height, underline, strikeout,
  superscript/subscript
- `hb-style`: `hb_style_get_value` (weight, width, slant, optical size)
- `hb-ot-layout`: script/language/feature/lookup enumeration, baselines,
  GDEF glyph classes
- `hb_set_t` / `hb_map_t` — a prerequisite for several of the queries above

## Phase 4 — Beyond shaping

- **`hb-ot-color`**: COLR/CPAL palettes, `glyph_get_png`, `glyph_get_svg`,
  `has_paint`. This is what actual colour emoji rendering needs, and colour
  emoji is the package's stated motivation.
- **`draw` / `paint`**: `hb_font_draw_glyph` with `hb_draw_funcs_t` (outline
  extraction to a callback-based path) and `hb_font_paint_glyph` with
  `hb_paint_funcs_t`. `uharfbuzz` additionally exposes a fontTools-compatible
  pen protocol; a Julia equivalent could target existing plotting/graphics
  packages.
- **`hb-ot-math`**: constants, glyph variants, assemblies, italics
  correction, math kerning. Relevant to a scientific ecosystem.
- **Subsetting**: `hb_subset`, `SubsetInput`, `SubsetPlan`, the repacker.
  `libharfbuzz_subset` already ships in the JLL.
- **`hb_unicode_funcs_t`**: script, combining class, mirroring, decomposition
  — exposes HarfBuzz's own Unicode data.

## Ergonomics (throughout)

- `show` methods for handles and results; make `ShapeResult` iterable and
  indexable
- Enums as Julia enums internally, `Symbol` at the API surface
  (`direction = :ltr`, `script = :Arab`)
- Document the threading model (HarfBuzz objects are not thread-safe unless
  made immutable)
- Reusable shaping test data from
  [`harfbuzz-testing-wikipedia`](https://github.com/harfbuzz/harfbuzz-testing-wikipedia)
  and [`harfbuzz-hazmat`](https://github.com/harfbuzz/harfbuzz-hazmat),
  once buffer serialisation exists

## Open questions

These need a decision before the corresponding work starts. Several affect
the public API and are cheapest to settle before 0.1.0 is released.

1. **Type naming.** Keep the `Hb` prefix (`HbFont`, `HbBuffer`, `HbFace`) or
   drop it and rely on module qualification (`HarfBuzz.Font`,
   `HarfBuzz.Buffer`)? The prefix is redundant in Julia, but dropping it
   makes `using HarfBuzz` export very generic names — which argues for
   dropping the prefix *and* exporting nothing by default. This is breaking
   after 0.1.0.

2. **Is FreeType the default backend or an extension?** Phase 1 proposes
   making `hb_ot_font_set_funcs` the default and moving FreeType behind a
   package extension. That changes the meaning of `HbFont(path, size)` —
   hinting, bitmap strikes, and metric rounding differ between the FreeType
   and OT funcs. Which should `HbFont(path, size)` select? Should there be
   an explicit `funcs = :ot | :ft` argument?

3. **What does `size` mean?** `HbFont(name, size)` currently takes an integer
   pixel size and hands it to `FT_Set_Char_Size`. With the native path the
   caller sets `hb_font_set_scale` directly, in font units. Options: keep
   pixels and convert, expose `scale` in font units, or accept both
   (`HbFont(face; size_px = 18)` vs `HbFont(face; scale = (upem, upem))`).
   Related: should positions be returned as raw 26.6 integers, or converted
   to `Float64` pixels?

4. **Does `FreeTypeAbstraction` stay a dependency at all?** It is used only
   for `findfont` family-name resolution, it mutates shared cached state
   (0.4 above), and font enumeration is arguably a separate concern. Options:
   keep it in the FreeType extension, replace it with `Fontconfig_jll`, or
   drop family-name resolution from this package entirely.

5. **How are features specified?** Today: `Vector{Tuple{String,Int}}`.
   Alternatives: a `Dict{String,Int}` like `uharfbuzz`, HarfBuzz's own string
   syntax via `hb_feature_from_string` (`"liga=0"`, `"+kern"`,
   `"aalt[3:5]=2"`), or a dedicated `HbFeature` struct carrying the range.
   The string syntax is the most portable across bindings and gets sub-range
   support for free.

6. **Zero-copy or copied results?** `unsafe_wrap` over the HarfBuzz buffer is
   fast and allocation-free, but the view is invalidated by the next
   `shape!`/`clear!` and by the buffer's finalizer. Copy by default and
   provide an opt-in view, or expose the view and document the hazard?

7. **Scope of the package.** Does `HarfBuzz.jl` stay a shaping library, or
   does it become the full binding (subsetting, drawing, painting, Unicode
   funcs)? If the latter, is that one package or a family
   (`HarfBuzz.jl` + `HarfBuzzSubset.jl`)?

8. **Package name and registration.** Is `HarfBuzz.jl` intended for the
   General registry? If so, the name should be checked against existing
   packages and against the JLL naming convention early, since renaming after
   registration is painful.

9. **Minimum HarfBuzz version.** Compat is currently pinned to
   `HarfBuzz_jll = "100.14002"`. Several Phase 3/4 functions
   (`hb_font_draw_glyph_or_fail`, `hb_font_is_synthetic`,
   `hb_ot_layout_script_select_language2`) appeared in specific upstream
   releases. Should the package feature-detect at load time, or simply
   require a recent JLL and document the floor?

10. **Testing without system fonts.** The current tests skip when no known
    system font is found, so CI coverage varies per platform. Should the
    package vendor a small permissively-licensed test font, or depend on an
    existing font JLL, so that shaping tests always run?
