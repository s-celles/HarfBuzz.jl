# HarfBuzz.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://s-celles.github.io/HarfBuzz.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://s-celles.github.io/HarfBuzz.jl/dev/)
[![Build Status](https://github.com/s-celles/HarfBuzz.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/s-celles/HarfBuzz.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

A Julia wrapper for the [HarfBuzz](https://harfbuzz.github.io/) text
shaping library, built on `HarfBuzz_jll`. FreeType is optional.

## Why

ImGui (and its Julia binding `CImGui.jl`) draws each Unicode codepoint
independently — there is no text shaping step. This means ligatures
(such as the regional-indicator pair `🇫🇷` → French flag) and ZWJ
sequences (`👨‍👩‍👧‍👦`) do not render correctly. `HarfBuzz.jl` provides the
shaping step that fills this gap.

## Usage

Nothing is exported — `Font`, `Face` and `Buffer` are too generic to put
in your namespace — so import the module under a short alias.

```julia
import HarfBuzz as HB

# Blob (bytes) → Face (tables) → Font (a face at a size)
font = HB.Font("/System/Library/Fonts/Menlo.ttc"; size = 18)

result = HB.shape(font, "Hello 漢字 🇫🇷")
for (info, pos) in zip(result.infos, result.positions)
    println("glyph=$(info.glyph_id) cluster=$(info.cluster) " *
            "advance=$(HB.px(pos.x_advance))px")
end

HB.has_glyph(font, UInt32('A'))       # true
HB.has_glyph(font, UInt32(0x6f22))    # false — Menlo lacks CJK
```

Advances and offsets come back in 26.6 fixed point; `HB.px` converts them
to pixels.

### Driving the buffer

`shape` is a shortcut; a buffer gives control over how the text is shaped
and lets you inspect the result.

```julia
buf = HB.Buffer()
HB.add_text!(buf, "مرحبا")
HB.guess_segment_properties!(buf)
HB.direction(buf)                  # :rtl
HB.script(buf)                     # :Arab

result = HB.shape!(font, buf)
HB.serialize(buf; font = font)     # same output as the hb-shape CLI
```

`unsafe_to_break(info)` tells a line breaker where a shaped run may not be
split.

### Inspecting a face

```julia
face = HB.Face("DejaVuSans.ttf")
HB.upem(face)         # 2048
HB.glyph_count(face)  # 6253
HB.table_tags(face)   # ["GDEF", "GPOS", "GSUB", "OS/2", ...]
HB.reference_table(face, "cmap")
```

### FreeType (optional)

HarfBuzz reads the font tables itself by default. FreeType lives behind a
package extension:

```julia
using FreeType                  # enables funcs = :freetype
font = HB.Font(face; size = 18, funcs = :freetype)
```

### Font files, not font names

This package matches no font names — HarfBuzz has no font database, and
neither do `uharfbuzz`, `harfbuzz_rs` or `harfbuzzjs`. Resolve a family
name with Fontconfig.jl, FreeTypeAbstraction.jl or a platform API, then
pass the resulting path.

## API

| Call | Description |
|---|---|
| `Blob(path)` / `Blob(bytes)` | Wrap font bytes |
| `Face(blob; index)` / `Face(path)` | A face inside those bytes |
| `Font(face; size, scale, funcs)` | A face at a size, ready to shape |
| `Font(path; size)` | Shorthand for a file on disk |
| `upem`, `glyph_count`, `face_index`, `face_count` | Face metadata |
| `table_tags`, `reference_table`, `data`, `unicodes` | Raw table access |
| `name(face, :family)`, `name_entries` | The `name` table |
| `glyph_h_advance(s)`, `glyph_extents`, `font_extents` | Glyph and line metrics |
| `glyph_name`, `glyph_from_name` | Glyph names |
| `metric(font, :x_height)`, `style(font, :weight)` | OpenType metrics and style |
| `axes`, `named_instances`, `set_variations!` | Variable fonts |
| `layout_feature_tags`, `glyph_class`, `baseline` | OpenType layout |
| `sub_font`, `synthetic_bold!`, `make_immutable!` | Font state |
| `scale`/`scale!`, `ppem`/`ppem!`, `ptem`/`ptem!` | Font size state |
| `Buffer()`, `add_text!`, `add_codepoints!`, `clear!`, `reset!` | Buffers |
| `direction`, `script`, `language`, `segment_properties` | Buffer properties |
| `flags`, `cluster_level`, `content_type` | Buffer behaviour |
| `shape(font, text; features, shapers)` | One-shot shaping |
| `features = ["kern=0", "liga" => 0]` | Feature strings, pairs or `Feature`s |
| `shape!(font, buf; features, shapers)` | Shape an existing buffer |
| `glyph_ids`, `clusters`, `px` | Result accessors |
| `unsafe_to_break`, `unsafe_to_concat` | Where a run may be split |
| `serialize`, `deserialize!`, `diff` | Golden-test support |
| `message_func!` | Trace shaping stages |
| `has_glyph`, `get_nominal_glyph` | Glyph availability |
| `version`, `shapers`, `tag`, `tag_string` | Library helpers |

See the [documentation](https://s-celles.github.io/HarfBuzz.jl/dev/) for
details, and [ROADMAP.md](ROADMAP.md) for what is still missing compared
to the HarfBuzz C API.
