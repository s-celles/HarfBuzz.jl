# Test fonts

Two subsets of **Noto Sans** are vendored so that the test suite asserts
real behaviour instead of skipping whenever a machine happens not to have
a given system font.

| File | Size | Used for |
|---|---|---|
| `NotoSans-subset.ttf` | 25 KB | shaping, features, glyph flags, metrics, names |
| `NotoSans-variable-subset.ttf` | 58 KB | variation axes and named instances |

Without it, 28 of the 53 test items depended on finding a system font and
returned silently when none was found — a bare CI container reported the
same green suite as a fully populated workstation.

## Provenance

| | |
|---|---|
| Source (static) | <https://github.com/googlefonts/noto-fonts> — `hinted/ttf/NotoSans/NotoSans-Regular.ttf` |
| Source (variable) | <https://github.com/notofonts/notofonts.github.io> — `fonts/NotoSans/unhinted/variable-ttf/NotoSans[wdth,wght].ttf` |
| Licence | SIL Open Font License 1.1, see `OFL.txt` |
| Reserved Font Name | none — the copyright notice carries no RFN clause, so a modified subset may be redistributed |
| Original sizes | 569 208 bytes (static), 1 581 884 bytes (variable) |
| Subset sizes | 25 328 bytes (static), 58 768 bytes (variable) |

## What the subset keeps

- Unicode: printable ASCII (U+0020–U+007E), a few Latin-1 accents
  (`À à é ê ñ`), U+0301 combining acute, U+2019 right single quote
- Tables: `GDEF GPOS GSUB OS/2 STAT cmap cvt fpgm gasp glyf head hhea hmtx
  loca maxp name post prep`
- 147 glyphs, 1000 units per em

Enough to exercise, deterministically:

| Behaviour | Test input | Observed |
|---|---|---|
| GPOS kerning | `"AVAWTo"` | advances change with `kern=0` |
| GSUB ligatures | `"office"` | 6 glyphs with `liga=0`, 4 with the `ffi` ligature |
| `unsafe_to_break` | `"AVA"` | flags `[0, 1, 1]` |
| Missing coverage | U+6F22 `漢` | `has_glyph` is `false` |

The variable subset keeps `fvar`, `gvar`, `avar`, `HVAR` and `MVAR`, so
variations are real rather than a no-op:

| Behaviour | Observed |
|---|---|
| Axes | `wght` 100–900 (default 400), `wdth` 62.5–100 (default 100) |
| Named instances | 9 |
| `wght` changes advances | `"Hi"` → `[813, 238]` at 100, `[854, 297]` at 400, `[882, 374]` at 900 |

## Reproducing it

The subset was produced with `libharfbuzz-subset`, which ships in
`HarfBuzz_jll` alongside `libharfbuzz`. Download the source font from the
URL above, then run this against it:

```julia
using HarfBuzz_jll
import HarfBuzz as HB

const libsub = HarfBuzz_jll.libharfbuzz_subset_path
const libhb  = HarfBuzz_jll.libharfbuzz_path

src, dst = "NotoSans-Regular.ttf", "NotoSans-subset.ttf"   # or the variable pair
face = HB.Face(src)

input = ccall((:hb_subset_input_create_or_fail, libsub), Ptr{Cvoid}, ())
uset = ccall((:hb_subset_input_unicode_set, libsub), Ptr{Cvoid}, (Ptr{Cvoid},), input)
for cp in vcat(0x20:0x7e, [0x00c0, 0x00e0, 0x00e9, 0x00ea, 0x00f1, 0x0301, 0x2019])
    ccall((:hb_set_add, libhb), Cvoid, (Ptr{Cvoid}, UInt32), uset, UInt32(cp))
end

out = ccall((:hb_subset_or_fail, libsub), Ptr{Cvoid},
            (Ptr{Cvoid}, Ptr{Cvoid}), face.ptr, input)
blob = ccall((:hb_face_reference_blob, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), out)
len = Ref{Cuint}(0)
ptr = ccall((:hb_blob_get_data, libhb), Ptr{UInt8}, (Ptr{Cvoid}, Ref{Cuint}), blob, len)
write(dst, unsafe_wrap(Array, ptr, Int(len[])))
```

Once the subsetting API is wrapped properly (Phase 4 of the roadmap), this
script becomes a few lines of ordinary `HarfBuzz.jl`.

## When to add another font

Only when a phase needs coverage these cannot give — a COLR/CPAL font for
the colour work in Phase 4, for instance. Not before. The variable subset
was added for exactly that reason when Phase 3 reached `fvar`/`avar`.
