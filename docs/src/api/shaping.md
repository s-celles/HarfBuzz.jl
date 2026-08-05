# Shaping

Text shaping is the core operation: given a font and a string,
HarfBuzz produces a sequence of glyph IDs, cluster mappings, and
positions.

```@docs
HarfBuzz.shape
HarfBuzz.shape!
```

## Features

Three spellings are accepted, each with a distinct job. `0` disables a
feature, `1` enables it, higher values select an alternate.

```julia
# 1. HarfBuzz's own syntax -- the canonical form, and the only one that
#    expresses everything. Same syntax as `hb-shape --features`.
HB.shape(font, "AVATAR"; features = ["kern=0"])
HB.shape(font, "office"; features = ["-liga"])
HB.shape(font, "hello";  features = ["aalt[3:5]=2"])     # over a range

# 2. Pairs, for the common global case.
HB.shape(font, "hello";  features = ["smcp" => 1])

# 3. `Feature` values, for features built programmatically.
HB.shape(font, "hello";  features = [HB.Feature("aalt", 2, 3, 5)])
```

`Dict` and `NamedTuple` are deliberately **not** accepted. Features apply
in order — the last entry for a tag wins — and the same tag may appear
more than once over different ranges:

```julia
HB.shape(font, text; features = ["kern[0:2]=0", "kern[2:6]=1"])
```

A `Dict` is unordered and neither it nor a `NamedTuple` can hold a
repeated tag or a range, so both would silently drop capability.

```@docs
HarfBuzz.Feature
```

## Glyph flags

A shaped run cannot always be split at an arbitrary glyph: breaking inside
a cluster the shaper joined would change the result. These predicates are
what a line breaker consults.

```@docs
HarfBuzz.unsafe_to_break
HarfBuzz.unsafe_to_concat
HarfBuzz.safe_to_insert_tatweel
```

## Result accessors

```@docs
HarfBuzz.glyph_ids
HarfBuzz.clusters
HarfBuzz.px
```

## Shapers

```@docs
HarfBuzz.shapers
```
