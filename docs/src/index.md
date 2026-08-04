# HarfBuzz.jl

A minimal Julia wrapper for the [HarfBuzz](https://harfbuzz.github.io/)
text shaping library, built on `HarfBuzz_jll` and `FreeType.jl`.

## Why

ImGui (and its Julia binding `CImGui.jl`) draws each Unicode codepoint
independently — there is no text shaping step. This means ligatures
(such as the regional-indicator pair `🇫🇷` → French flag) and ZWJ
sequences (`👨‍👩‍👧‍👦`) do not render correctly. `HarfBuzz.jl` provides the
shaping step that fills this gap.

## Quick start

```julia
using HarfBuzz

# Open a font via FreeType (recommended — provides glyph advances)
font = HbFont("/System/Library/Fonts/Menlo.ttc", 18)

# Shape text: returns glyph IDs, clusters, and positions
result = shape(font, "Hello 漢字 🇫🇷")
for (info, pos) in zip(result.infos, result.positions)
    println("glyph=$(info.glyph_id) cluster=$(info.cluster) advance=$(pos.x_advance)")
end

# Check if a font has a glyph
has_glyph(font, UInt32('A'))     # true
has_glyph(font, UInt32(0x6f22))  # false — Menlo lacks CJK
```

## Architecture

```
HarfBuzz.jl (Julia wrapper)
  ├── HarfBuzz_jll (binary library)
  ├── FreeType.jl (font loading + glyph advances)
  └── ccall bindings to libharfbuzz
```

`HarfBuzz.jl` uses `FreeType.jl` to open font files and create
`FT_Face` objects. HarfBuzz's `hb_ft_font_create` then wraps the
`FT_Face` into an `hb_font_t` that can shape text and return glyph
advances and positions. Without FreeType backing, HarfBuzz can shape
(produce glyph IDs and clusters) but cannot provide advances.

## API overview

| Function | Description |
|---|---|
| `HbFont(path, size)` | Open a font at `size` pixels via FreeType |
| `shape(font, text)` | Shape text → `ShapeResult` (glyphs + positions) |
| `has_glyph(font, cp)` | Check if font contains a Unicode codepoint |
| `get_nominal_glyph(font, cp)` | Get glyph ID for a codepoint |

See the [API](@ref) section for details.