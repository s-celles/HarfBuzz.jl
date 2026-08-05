# HarfBuzz.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://s-celles.github.io/HarfBuzz.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://s-celles.github.io/HarfBuzz.jl/dev/)
[![Build Status](https://github.com/s-celles/HarfBuzz.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/s-celles/HarfBuzz.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

A minimal Julia wrapper for the [HarfBuzz](https://harfbuzz.github.io/) text
shaping library, built on `HarfBuzz_jll` and `FreeType.jl`.

## Why

ImGui (and its Julia binding `CImGui.jl`) draws each Unicode codepoint
independently — there is no text shaping step. This means ligatures
(such as the regional-indicator pair `🇫🇷` → French flag) and ZWJ
sequences (`👨‍👩‍👧‍👦`) do not render correctly. `HarfBuzz.jl` provides the
shaping step that fills this gap.

## Usage

```julia
using HarfBuzz

# Open a font by path or family name
font = HbFont("/System/Library/Fonts/Menlo.ttc", 18)
font = HbFont("DejaVu Sans Mono", 18)   # resolved via FreeTypeAbstraction

# Shape text: returns glyph IDs, clusters, and positions
result = shape(font, "Hello 漢字 🇫🇷")
for (info, pos) in zip(result.infos, result.positions)
    println("glyph=$(info.glyph_id) cluster=$(info.cluster) advance=$(pos.x_advance)")
end

# Check if a font has a glyph
has_glyph(font, UInt32('A'))       # true
has_glyph(font, UInt32(0x6f22))   # false — Menlo lacks CJK
```

## API

| Function | Description |
|---|---|
| `HbFont(path_or_name, size)` | Open a font at `size` pixels (path or family name) |
| `HbBuffer()` | Create a shaping buffer |
| `add_text!(buf, text)` | Add UTF-8 text to a buffer |
| `guess_segment_properties!(buf)` | Guess script/direction from buffer content |
| `shape!(font, buf; features)` | Shape in-place, returns `ShapeResult` |
| `shape(font, text; features)` | One-shot convenience shaping |
| `glyph_ids(result)` | Extract glyph IDs from a `ShapeResult` |
| `clusters(result)` | Extract cluster indices from a `ShapeResult` |
| `has_glyph(font, codepoint)` | Check if font contains a Unicode codepoint |
| `get_nominal_glyph(font, codepoint)` | Get glyph ID for a codepoint |

See the [documentation](https://s-celles.github.io/HarfBuzz.jl/dev/) for details.