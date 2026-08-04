# HarfBuzz.jl

A minimal Julia wrapper for the [HarfBuzz](https://harfbuzz.github.io/) text
shaping library, built on `HarfBuzz_jll`.

## Why

ImGui (and its Julia binding `CImGui.jl`) draws each Unicode codepoint
independently — there is no text shaping step. This means ligatures
(such as the regional-indicator pair `🇫🇷` → French flag) and ZWJ
sequences (`👨‍👩‍👧‍👦`) do not render correctly. `HarfBuzz.jl` provides the
shaping step that fills this gap.

## Usage

```julia
using HarfBuzz

face = HbFace("/System/Library/Fonts/Menlo.ttc")
font = HbFont(face, 18)

# Shape text
result = shape(font, "Hello 漢字 🇫🇷")

# Glyph IDs and positions
for (info, pos) in zip(result.infos, result.positions)
    println("glyph=$(info.glyph_id) cluster=$(info.cluster) advance=$(pos.x_advance)")
end

# Check if a font has a glyph
has_glyph(font, UInt32('A'))     # true
has_glyph(font, 0x6f22)          # false — Menlo lacks CJK
```

## API

- `HbBlob(path)` — font file blob
- `HbFace(blob, index=0)` / `HbFace(path, index=0)` — font face
- `HbFont(face, size)` — scaled font at `size` pixels
- `HbBuffer()` — shaping buffer
- `add_text!(buf, text)` — add UTF-8 text
- `guess_segment_properties!(buf)` — guess script/direction
- `shape!(font, buf; features)` — shape, returns `ShapeResult`
- `shape(font, text; features)` — one-shot convenience
- `has_glyph(font, codepoint)` — check glyph availability
- `get_nominal_glyph(font, codepoint)` — glyph ID for a codepoint