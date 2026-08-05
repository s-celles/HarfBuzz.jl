# Shaping

Text shaping is the core operation: given a font and a string,
HarfBuzz produces a sequence of glyph IDs, cluster mappings, and
positions.

```@docs
HarfBuzz.shape
HarfBuzz.shape!
```

## Features

Features can be given as [`Feature`](@ref HarfBuzz.Feature) values,
HarfBuzz feature strings, or `name => value` pairs — `0` disables a
feature, `1` enables it, higher values select an alternate.

```julia
HB.shape(font, "AVATAR"; features = ["kern=0"])          # no kerning
HB.shape(font, "office"; features = ["-liga"])           # no ligatures
HB.shape(font, "hello";  features = [("smcp", 1)])       # small caps
HB.shape(font, "hello";  features = ["aalt[3:5]=2"])     # over a range
```

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
