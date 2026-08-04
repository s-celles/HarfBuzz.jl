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

## Result accessors

```@docs
HarfBuzz.glyph_ids
HarfBuzz.clusters
```

## Scale

```@docs
HarfBuzz.set_scale!
```