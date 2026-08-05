# Shaping

Text shaping is the core operation: given a font and a string,
HarfBuzz produces a sequence of glyph IDs, cluster mappings, and
positions.

## Buffer management

```@docs
HarfBuzz.clear!
HarfBuzz.add_text!
HarfBuzz.guess_segment_properties!
```

## Shaping

```@docs
HarfBuzz.shape!
HarfBuzz.shape
```

## Features

Features are passed as `name => value` pairs, where the name is an
OpenType feature tag and `0` disables the feature, `1` enables it, and
higher values select an alternate. They apply to the whole buffer.

```julia
HB.shape(font, "AVATAR"; features = [("kern", 0)])   # no kerning
HB.shape(font, "office"; features = [("liga", 0)])   # no ligatures
```

## Result accessors

```@docs
HarfBuzz.glyph_ids
HarfBuzz.clusters
HarfBuzz.px
```
