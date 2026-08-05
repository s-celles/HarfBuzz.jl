# Buffers

A buffer holds the text to shape, then the glyphs shaping produced. Its
properties — direction, script, language — decide how the text is shaped,
so set them (or let HarfBuzz guess) before calling
[`shape!`](@ref HarfBuzz.shape!).

```julia
import HarfBuzz as HB

buf = HB.Buffer()
HB.add_text!(buf, "مرحبا")
HB.guess_segment_properties!(buf)
HB.direction(buf)   # :rtl
HB.script(buf)      # :Arab
```

## Contents

```@docs
HarfBuzz.add_text!
HarfBuzz.add_codepoints!
HarfBuzz.clear!
HarfBuzz.reset!
HarfBuzz.reverse_clusters!
HarfBuzz.pre_allocate!
HarfBuzz.allocation_successful
```

`length(buf)` gives the item count, `isempty(buf)` tests it,
`append!(dest, src)` joins two buffers, and `reverse!(buf)` reverses the
contents.

## Reading a buffer

```@docs
HarfBuzz.glyph_infos
HarfBuzz.glyph_positions
HarfBuzz.codepoints
HarfBuzz.has_positions
```

## Properties

```@docs
HarfBuzz.direction
HarfBuzz.script
HarfBuzz.language
HarfBuzz.segment_properties
HarfBuzz.guess_segment_properties!
HarfBuzz.flags
HarfBuzz.cluster_level
HarfBuzz.content_type
HarfBuzz.replacement_codepoint
HarfBuzz.invisible_glyph
HarfBuzz.not_found_glyph
```

## Serialization

Serializing is the practical way to write golden tests: shape, serialize,
compare against a stored string — the same thing the `hb-shape`
command-line tool prints.

```@docs
HarfBuzz.serialize
HarfBuzz.deserialize!
HarfBuzz.diff
```

## Tracing

```@docs
HarfBuzz.message_func!
```
