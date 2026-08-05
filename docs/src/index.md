# HarfBuzz.jl

A Julia wrapper for the [HarfBuzz](https://harfbuzz.github.io/)
text shaping library, built on `HarfBuzz_jll`.

## Why

ImGui (and its Julia binding `CImGui.jl`) draws each Unicode codepoint
independently — there is no text shaping step. This means ligatures
(such as the regional-indicator pair `🇫🇷` → French flag) and ZWJ
sequences (`👨‍👩‍👧‍👦`) do not render correctly. `HarfBuzz.jl` provides the
shaping step that fills this gap.

## Quick start

Nothing is exported — `Font`, `Face` and `Buffer` are too generic to put
in your namespace — so import the module under a short alias.

```julia
import HarfBuzz as HB

font = HB.Font("/System/Library/Fonts/Menlo.ttc"; size = 18)

result = HB.shape(font, "Hello 漢字 🇫🇷")
for (info, pos) in zip(result.infos, result.positions)
    println("glyph=$(info.glyph_id) cluster=$(info.cluster) " *
            "advance=$(HB.px(pos.x_advance))px")
end

HB.has_glyph(font, UInt32('A'))     # true
HB.has_glyph(font, UInt32(0x6f22))  # false — Menlo lacks CJK
```

## Object chain

```
Blob      raw bytes (a font file, or a Julia array)
 └─ Face  the font tables inside those bytes
     └─ Font   a face at a given size, ready to shape
```

Each object keeps the one below it alive, so the shorthands
`HB.Face(path)` and `HB.Font(path; size)` are safe to use on their own.

```julia
blob = HB.Blob("DejaVuSans.ttf")
face = HB.Face(blob)            # or HB.Face(path)
font = HB.Font(face; size = 18) # or HB.Font(path; size = 18)

HB.upem(face)         # 2048
HB.glyph_count(face)  # 6253
HB.table_tags(face)   # ["GDEF", "GPOS", "GSUB", "OS/2", ...]
```

## Sizes and units

`size` is in pixels and sets the font scale to `size * 64`, so advances
and offsets come back in 26.6 fixed point. `HB.px` converts them.

```julia
font = HB.Font(face; size = 18)
HB.scale(font)                                       # (1152, 1152)
HB.px(HB.shape(font, "M").positions[1].x_advance)    # 10.84375
```

`scale` can also be set directly, in font units, which bypasses the
pixel convenience entirely:

```julia
font = HB.Font(face; scale = (2048, 2048))
```

## Metrics backends

By default HarfBuzz reads the font tables itself (`hb_ot_font_set_funcs`),
so the package depends only on `HarfBuzz_jll`.

FreeType is optional and lives behind package extensions:

```julia
using FreeType                  # loads the :freetype backend
font = HB.Font(face; size = 18, funcs = :freetype)

using FreeTypeAbstraction       # enables family-name lookup
font = HB.Font("DejaVu Sans Mono"; size = 18)
```

Family names need a font database, which HarfBuzz does not provide; fonts
opened that way are always FreeType-backed. Without the extension loaded,
both calls raise an `ArgumentError` naming the package to add.

## API overview

| Call | Description |
|---|---|
| `HB.Blob(path)` / `HB.Blob(bytes)` | Wrap font bytes |
| `HB.Face(blob; index)` | A face inside those bytes |
| `HB.Font(face; size)` | A face at a size, ready to shape |
| `HB.shape(font, text)` | Shape text → `ShapeResult` |
| `HB.px(v)` | 26.6 fixed point → pixels |
| `HB.has_glyph(font, cp)` | Does the font cover this codepoint? |

See the [Types](api/types.md), [Shaping](api/shaping.md), and
[Font queries](api/queries.md) pages for details.
