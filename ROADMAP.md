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

`HarfBuzz.jl` binds **162 of the 508 `hb_*` symbols** exported by
`libharfbuzz` in the JLL, plus the subsetting entry points in
`libharfbuzz-subset`. Only `libharfbuzz-gobject`, which exists for GObject
introspection bindings, goes unused.

All four phases are done. Shaping is correct and complete, the
`Blob → Face → Font` chain uses HarfBuzz's own table reader by default (so
the package depends only on `HarfBuzz_jll`), buffers expose segment
properties, glyph flags and serialization, fonts and faces can be queried
down to variation axes and layout tables, and outlines, colour, math,
subsetting and Unicode data are all reachable.

What is left is judgement calls rather than coverage: the open questions
below, and `hb_paint_funcs_t`, which Phase 4 deliberately leaves alone.

## Phase 0 — Correctness — **done**

Three defects were confirmed against the JLL headers and by measurement,
then fixed test-first. A fourth problem surfaced while fixing them (0.5).

### 0.1 `hb_ft_font_create` is called with one argument instead of two — fixed

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

### 0.2 `_HB_GLYPH_POS_SIZE` is 24; `hb_glyph_position_t` is 20 bytes — fixed

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

### 0.3 Shaping features are silently ignored — fixed

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

- `_name_to_tag` mixed `sizeof(s)` (bytes) with `s[i]` (character indexing).
  Fixed by indexing `codeunits`. `hb_tag_from_string` could replace it
  outright in Phase 2.
- The family-name branch of `HbFont` ignored the `FT_Set_Char_Size` return
  code. Fixed.
- One `FT_Library` was created per `HbFont` and never destroyed. Replaced by
  a single module-level library created in `__init__`.
- `add_text!` did not expose `item_offset` / `item_length`, so no context
  could be supplied around the shaped run (needed for correct contextual
  forms at run boundaries, e.g. Arabic). Done in Phase 2.
- `hb_buffer_allocation_successful` was never checked. Done in Phase 2:
  every mutation checks it and raises `OutOfMemoryError`.

### 0.5 Use-after-free at process teardown — fixed

Calling `hb_font_destroy` for real (0.1) exposed a second crash, at exit
rather than during the run. `FreeTypeAbstraction.__init__` registers
`atexit(ft_done)`, which calls `FT_Done_FreeType` and frees every face its
library owns. Julia runs `atexit` hooks *before* the final round of
finalizers, so an `HbFont` finalized at teardown called `FT_Done_Face` (via
HarfBuzz's destroy callback) on freed memory — a reliable segfault at the
end of an otherwise green test run.

`HarfBuzz.__init__` now registers its own `atexit` hook setting an
`_EXITING` flag, and `_hb_font_destroy` skips the call when it is set.
Leaking at teardown is free; the process is exiting. `FreeTypeAbstraction`
guards its own finalizer the same way.

Note for Phase 1: this hazard exists only because the `FT_Face` is owned by
another package's `FT_Library`. Making the native `hb-ot` path the default
removes it. (`findfont` also opens and scores *every* font file in every
font directory on each call, so the family-name branch is expensive as well
as fragile.)

## Phase 1 — Object model — **done**

The structural gap was that there was no `Blob` and no `Face`. Every other
binding exposes the `Blob → Face → Font` chain, and HarfBuzz can supply
glyph metrics itself through `hb_ot_font_set_funcs` — FreeType is optional.
FreeType and FreeTypeAbstraction were hard dependencies, so a font could not
be loaded from bytes in memory and tables could not be reached at all.

Shipped:

- `Blob`: `hb_blob_create_from_file_or_fail`, `hb_blob_create_or_fail` over a
  Julia array without copying, `length`, `data`, `face_count`
- `Face`: `hb_face_create(blob, index)`, `upem`, `glyph_count`, `face_index`,
  `table_tags`, `reference_table`
- `Font(face)` with `hb_ot_font_set_funcs` — the default, no FreeType
- `scale`/`scale!`, `ppem`/`ppem!`, `ptem`/`ptem!`, and `px` for 26.6 → pixels
- `FreeType` moved to a `weakdep` behind `HarfBuzzFreeTypeExt` (the
  `funcs = :freetype` backend, over `FT_New_Memory_Face` on the face's own
  blob). The package now depends only on `HarfBuzz_jll`.
- Types lost the `Hb` prefix and the module exports nothing

Both paths — native and `funcs = :freetype` — produce identical advances
on the same font and size.

Deferred to Phase 3, where they sit with the rest of the font API:
`hb_font_create_sub_font`, synthetic bold and slant, immutability,
`face.unicodes` (needs `hb_set_t`).

## Phase 2 — Buffer API — **done**

Shipped:

- Properties: `direction`, `script`, `language`, `flags`, `cluster_level`,
  `content_type`, `invisible_glyph`, `not_found_glyph`,
  `replacement_codepoint`, and `segment_properties` for all three segment
  properties at once. Enumerations are `Symbol`s at the surface (`:ltr`,
  `:Arab`, `:monotone_graphemes`) and integers underneath.
- Input: `add_codepoints!`, `append!`, and `item_offset`/`item_length` on
  `add_text!` so a run carries its surrounding context
- Manipulation: `reset!`, `reverse!`, `reverse_clusters!`, `length`,
  `isempty`, `pre_allocate!`, `allocation_successful`, `diff`
- `serialize` / `deserialize!` in both text and JSON, matching what the
  `hb-shape` CLI prints — the basis for golden tests
- `message_func!` for tracing shaping steps, i.e. `hb-shape --trace`
- Glyph flags on `GlyphInfo`, with `unsafe_to_break`, `unsafe_to_concat`
  and `safe_to_insert_tatweel`. `unsafe_to_break` is what line breaking
  needs, which is directly relevant to the ImGui use case.
- Common types: direction, script and language conversions, `tag` ↔
  `tag_string`, `version`, `version_string`
- `hb_shape_full` through `shape!(...; shapers = ["ot"])`, plus `shapers()`
- Features parse from HarfBuzz's own syntax (`"kern=0"`, `"-liga"`,
  `"aalt[3:5]=2"`) and print back to it

Not done, and not worth their own phase — pick them up when something
needs them: `hb_buffer_add_utf16` / `add_utf32` / `add_latin1` (Julia
strings are UTF-8, and `add_codepoints!` covers decoded input),
`hb_buffer_create_similar`, `hb_buffer_normalize_glyphs`,
`hb_buffer_serialize_unicode` / `deserialize_unicode`,
`hb_buffer_set_unicode_funcs`.

Testing note: assertions about *which* glyphs come back unsafe to break
used to be font-dependent and were therefore weakened. With the vendored
test font (open question 10, now decided) they are real again: `"AVA"`
yields flags `[0, 1, 1]` deterministically.

## Phase 3 — Font and face queries — **done**

Shipped:

- Glyph metrics: `glyph_h_advance`, `glyph_v_advance`, the batch
  `glyph_h_advances`, `glyph_extents`, `glyph_h_origin`, `glyph_v_origin`,
  `font_extents`, `glyph_h_kerning` (legacy `kern` table only — GPOS
  kerning arrives through shaping)
- Glyph names: `glyph_name`, `glyph_from_name`
- `unicodes(face)`, returning a Julia `Set{UInt32}`. `hb_set_t` stays
  internal: HarfBuzz only uses it as an out-parameter, and a wrapper nobody
  would keep around is not worth the API surface.
- `hb-ot-name`: `name(face, :family)` and friends by symbol or numeric id,
  plus `name_entries` to list what a font actually carries
- `hb-ot-metrics`: `metric(font, :x_height)` and the other 27 tags, with
  HarfBuzz's fallback synthesis on by default
- `hb-style`: `style(font, :weight)`, which follows any variation set
- `hb-ot-var`: `has_variations`, `axes`, `named_instances`,
  `set_variations!`, `var_coords_design`, `var_coords_normalized`
- `hb-ot-layout`: `has_substitution`, `has_positioning`,
  `has_glyph_classes`, `layout_script_tags`, `layout_feature_tags`,
  `glyph_class`, `baseline`
- Deferred from Phase 1 and now done: `sub_font`, `synthetic_bold`/`!`,
  `synthetic_slant`/`!`, `is_synthetic`, `make_immutable!`, `is_immutable`

A second vendored font was needed for this phase, as anticipated:
`test/fonts/NotoSans-variable-subset.ttf`, 58 KB, two axes and nine named
instances, so `fvar` assertions are real rather than "no axes, no crash".

Two test expectations turned out to be wrong about the world rather than
about the code, which is what asserting against a known font is for:
`hb_style_get_value` reports weight 100 and width 62.5 for the *upstream*
static Noto Sans, because its `STAT` table declares the family minimums
rather than its own instance values; and `hb-subset` drops `post` glyph
names unless `HB_SUBSET_FLAGS_GLYPH_NAMES` is set, which the vendored
subsets now use.

Not done, and cheap to add when something needs them:
`hb_font_get_glyph_contour_point`, the `*_for_direction` origin helpers,
`hb_ot_layout_collect_lookups`, `hb_ot_layout_lookup_get_glyph_alternates`,
custom `hb_font_funcs_t`.

## Phase 4 — Beyond shaping — **done**

Shipped:

- **Outlines**: `outline(font, glyph)` returning path commands, and the
  callback form `draw_glyph(f, font, glyph)` over `hb_draw_funcs_t`. This
  is what a Julia renderer needs to draw text itself.
- **`hb-ot-color`**: `has_color_palettes` / `_layers` / `_paint` / `_png` /
  `_svg`, `color_palette_count`, `color_palette`, `color_palette_flags`,
  `glyph_color_layers`, `glyph_has_color_paint`, `glyph_color_png`,
  `glyph_color_svg`, with a `Color` struct.
- **`hb-ot-math`**: `has_math_data`, `math_constant` over all 56 constants,
  `math_italics_correction`, `math_top_accent_attachment`,
  `is_math_extended_shape`, `math_min_connector_overlap`,
  `math_glyph_variants`, `math_glyph_assembly`.
- **Subsetting**: `subset(face; unicodes, glyphs, flags)`, over
  `libharfbuzz-subset` — which the JLL had always shipped and nothing used.
  The vendored test fonts are now produced by the package itself.
- **`hb_unicode_funcs_t`**: `script_of`, `general_category`,
  `combining_class`, `mirroring`, `compose`, `decompose`, from HarfBuzz's
  own Unicode tables — the same ones shaping uses.

Two more vendored fonts were needed, as anticipated:
`NotoSansMath-subset.ttf` (25 KB, `MATH`) and `NotoColor-subset.ttf`
(6 KB, COLR/CPAL with COLRv1 paint). Both OFL, both without a Reserved
Font Name.

**Paint is deliberately not wrapped.** `hb_paint_funcs_t` is a far larger
surface than `hb_draw_funcs_t`: colour lines, four gradient kinds, affine
transforms, clips, and Porter-Duff composite modes, all as callbacks whose
output is only useful to a renderer that already has an equivalent model.
Wrapping it faithfully means designing a Julia colour/paint vocabulary,
which belongs with the renderer that needs it rather than in the binding.
`glyph_has_color_paint` and `glyph_color_png` cover the practical cases in
the meantime.

Also not done, and cheap when needed: `hb_ot_math_get_glyph_kerning`,
`hb_subset_plan_*`, the repacker, `hb_subset_input_set_axis_range`
(instancing a variable font), and custom `hb_unicode_funcs_t`.

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

## Decided

1. **Type naming.** ~~Keep the `Hb` prefix?~~ **No prefix, and no exports.**
   Types are `Font`, `Face`, `Buffer`, `Blob`, `Feature`, reached through the
   module (`import HarfBuzz as HB`). The prefix is redundant when Julia
   already namespaces by module, and the bare names are far too generic to
   export.

2. **Default backend.** ~~FreeType or `hb-ot`?~~ **`hb-ot` natively, by
   default.** `funcs = :freetype` stays available through the FreeType
   extension for callers who need FreeType's hinting and rounding. The
   package depends only on `HarfBuzz_jll`.

3. **What `size` means.** **Pixels, with raw 26.6 output.** `size = 18` sets
   the scale to `18 * 64`; `scale = (x, y)` sets it directly in font units
   and takes precedence. Positions stay `Int32` in 26.6 — `px` converts.

4. **Does `FreeTypeAbstraction` stay a dependency?** **No — family-name
   resolution is gone.** `Font` takes a path; anything else raises an
   `ArgumentError` pointing at Fontconfig.jl, FreeTypeAbstraction.jl or a
   platform API. Three reasons:

   - `FTFont` exposes no file path (its fields are `ft_ptr`, `use_cache`,
     `extent_cache`, `lock`, `mmapped`, `fontname`), so a family name could
     never reach the native backend. `Font(name)` was permanently
     FreeType-backed while `Font(path)` was OT-backed — the same call
     shape giving different metrics.
   - No official binding does font matching. uharfbuzz, harfbuzz_rs,
     harfbuzzjs and luaharfbuzz all take bytes or a path; HarfBuzz upstream
     leaves enumeration to fontconfig, CoreText and DirectWrite.
   - `findfont` measured 14 ms per call here, opening and scoring all 580
     files in the four font directories, with no cache.

   Should family lookup ever come back, `Fontconfig_jll` is the better base
   than FreeTypeAbstraction: it returns a *path*, so the native backend
   keeps working, and it already ships as an indirect dependency of
   `HarfBuzz_jll` — no extra download. It would still belong in its own
   extension, and would return a path rather than a `Font`.

5. **How are features specified?** **Three forms, no `Dict`, no
   `NamedTuple`.** HarfBuzz's own string syntax is canonical (`"kern=0"`,
   `"-liga"`, `"aalt[3:5]=2"`) — it is the only form that expresses
   everything, it matches `hb-shape --features` and every other binding's
   documentation, and `hb_feature_from_string` does the parsing so there is
   nothing to keep in sync. `"tag" => value` pairs cover the common global
   case; `Feature` values cover programmatic construction. The `Tuple` form
   was dropped as strictly dominated by pairs.

   `Dict` and `NamedTuple` are rejected on measured grounds, not taste.
   Features apply in order and the same tag may appear more than once over
   different ranges (Times New Roman, `"AVAWTo"`):

   ```
   default                          [758, 684, 712, 1041, 664, 536]
   kern=0 global                    [832, 832, 832, 1087, 704, 576]
   kern=0 over [0:3) only           [832, 832, 832, 1087, 664, 536]
   kern=0 [0:2) then kern=1 [2:6)   [832, 832, 786, 1041, 664, 536]
   kern=0 then kern=1 (global)      [758, 684, 712, 1041, 664, 536]
   kern=1 then kern=0 (global)      [832, 832, 832, 1087, 704, 576]
   ```

   A `Dict` is unordered; neither it nor a `NamedTuple` can hold a repeated
   tag or a range. Both would silently drop capability, and a caller who
   started with one would have to rewrite as soon as a range was needed.

10. **Testing without system fonts.** **A subset of Noto Sans is vendored**
    in `test/fonts/`, 25 KB, under the OFL (no Reserved Font Name, so a
    modified subset may be redistributed). Every assertion about shaping now
    runs against it.

    28 of the 53 test items previously depended on finding a system font and
    returned in silence when none was found — a bare CI container reported
    the same green suite as a full workstation. Two assertions had already
    been weakened to survive that (`unsafe_to_break`, kerning) and every
    Phase 3 and 4 assertion would have had to be.

    "Depend on an existing font JLL" was not a real option: no package in the
    General registry ships font files (the `DejaVu` package there is a
    CxxWrap graph library), so it would have meant creating and registering
    one.

    The subset was produced with `libharfbuzz-subset`, which the JLL already
    ships; `test/fonts/README.md` records the source, the licence and the
    exact script. The few tests that still need a system font (CJK coverage,
    an arbitrary real-world file) now use `@test_skip`, so they appear in the
    summary as *Broken* rather than vanishing.

    A second font is warranted only when a phase needs coverage this one
    cannot give: a variable font for `fvar`/`avar` in Phase 3, or a
    COLR/CPAL font for colour in Phase 4.

## Open questions

These need a decision before the corresponding work starts. Several affect
the public API and are cheapest to settle before 0.1.0 is released.

6. **Zero-copy or copied results?** `unsafe_wrap` over the HarfBuzz buffer is
   fast and allocation-free, but the view is invalidated by the next
   `shape!`/`clear!` and by the buffer's finalizer. Copy by default and
   provide an opt-in view, or expose the view and document the hazard?

7. **Scope of the package.** Does `HarfBuzz.jl` stay a shaping library, or
   does it become the full binding (subsetting, drawing, painting, Unicode
   funcs)? If the latter, is that one package or a family
   (`HarfBuzz.jl` + `HarfBuzzSubset.jl`)?

8. **Where the repository lives, and when it is registered.** Registration
   in General is **deferred**: a transfer to another GitHub organisation is
   under consideration, and moving after registration is more disruptive
   than moving before.

   The name is not the constraint — `HarfBuzz` is free in General, which
   holds only `HarfBuzz_jll` and `HarfBuzz_ICU_jll`.

   The two candidate homes answer different questions:

   - **`harfbuzz/`** hosts the official bindings, all alive: `harfbuzzjs`
     (277★, pushed 2026-07-31), `uharfbuzz` (108★, 2026-07-31),
     `harfbuzz_rs` (64★, 2025-08), `luaharfbuzz` (13★, 2026-06). It signals
     "the Julia binding" and puts the package where people look for
     HarfBuzz. But upstream does not do Julia: nobody there would review
     Julia code, register the package, or mind TagBot and CompatHelper.
   - **`JuliaGraphics/`** hosts the technical neighbourhood: `FreeType.jl`,
     `FreeTypeAbstraction.jl`, `Fontconfig.jl`, `Cairo.jl`, `Luxor.jl`,
     `ColorTypes.jl`. Julia conventions are routine there, and the packages
     open question 4 named as the right owners of font matching —
     FreeTypeAbstraction and Fontconfig — are already in it, so a future
     `find_font` would have an obvious home. Activity is uneven, though:
     `Luxor.jl` was pushed 2026-08-02 and `ColorTypes.jl` 2026-07-04, but
     `FreeType.jl` has not moved since 2023-12 nor `Fontconfig.jl` since
     2023-01, so the promise of co-maintainers is partly theoretical.

   The two are not mutually exclusive in spirit: the package can live in
   JuliaGraphics and still be listed as the Julia binding from the
   `harfbuzz/` README or harfbuzz.github.io. That buys the upstream
   visibility without asking upstream to adopt Julia code, and costs an
   email rather than a transfer.

   Whichever is chosen, a transfer needs these updated — GitHub redirects
   URLs, but not file contents or secrets:

   - `docs/make.jl`: `repo = "github.com/s-celles/HarfBuzz.jl.git"` and
     `canonical = "https://s-celles.github.io/HarfBuzz.jl"`
   - `README.md`: the three badge URLs (docs stable, docs dev, CI)
   - `SECURITY.md`: the private advisory link
   - the `DOCUMENTER_KEY` secret, which does not follow the repository and
     must be regenerated
   - the `gh-pages` publication URL, so the documentation stays broken
     until both of the above are redone

9. **Minimum HarfBuzz version.** Compat is currently pinned to
   `HarfBuzz_jll = "100.14002"`. Several Phase 3/4 functions
   (`hb_font_draw_glyph_or_fail`, `hb_font_is_synthetic`,
   `hb_ot_layout_script_select_language2`) appeared in specific upstream
   releases. Should the package feature-detect at load time, or simply
   require a recent JLL and document the floor?

