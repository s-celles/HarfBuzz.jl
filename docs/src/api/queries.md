# Font queries

## Library

```@docs
HarfBuzz.version
HarfBuzz.version_string
HarfBuzz.tag
HarfBuzz.tag_string
```

## Blob contents

```@docs
HarfBuzz.data
HarfBuzz.face_count
```

## Face metadata

```@docs
HarfBuzz.upem
HarfBuzz.glyph_count
HarfBuzz.face_index
HarfBuzz.table_tags
HarfBuzz.reference_table
HarfBuzz.unicodes
```

## The name table

```@docs
HarfBuzz.name
HarfBuzz.name_entries
```

## Font size and metrics state

`scale`, `ppem` and `ptem` each have a setter suffixed with `!`
(`scale!`, `ppem!`, `ptem!`).

```@docs
HarfBuzz.scale
HarfBuzz.ppem
HarfBuzz.ptem
```

## Glyph metrics

Everything here is in the font's scale units, which `size` sets to 26.6
fixed point; [`px`](@ref HarfBuzz.px) converts.

```@docs
HarfBuzz.glyph_h_advance
HarfBuzz.glyph_h_advances
HarfBuzz.glyph_extents
HarfBuzz.font_extents
HarfBuzz.glyph_h_origin
HarfBuzz.glyph_h_kerning
HarfBuzz.GlyphExtents
HarfBuzz.FontExtents
```

## Glyph availability and names

```@docs
HarfBuzz.has_glyph
HarfBuzz.get_nominal_glyph
HarfBuzz.glyph_name
HarfBuzz.glyph_from_name
```

## OpenType metrics and style

```@docs
HarfBuzz.metric
HarfBuzz.style
```

## Variable fonts

```@docs
HarfBuzz.has_variations
HarfBuzz.axes
HarfBuzz.named_instances
HarfBuzz.set_variations!
HarfBuzz.var_coords_design
```

## OpenType layout

```@docs
HarfBuzz.has_substitution
HarfBuzz.layout_script_tags
HarfBuzz.layout_feature_tags
HarfBuzz.glyph_class
HarfBuzz.baseline
```

## Font state

```@docs
HarfBuzz.sub_font
HarfBuzz.synthetic_slant
HarfBuzz.synthetic_bold
HarfBuzz.is_synthetic
HarfBuzz.make_immutable!
```

## Outlines

```@docs
HarfBuzz.outline
HarfBuzz.draw_glyph
HarfBuzz.PathCommand
```

## Colour

```@docs
HarfBuzz.has_color_palettes
HarfBuzz.color_palette_count
HarfBuzz.color_palette
HarfBuzz.color_palette_flags
HarfBuzz.glyph_color_layers
HarfBuzz.glyph_has_color_paint
HarfBuzz.glyph_color_png
HarfBuzz.Color
```

## Math

```@docs
HarfBuzz.has_math_data
HarfBuzz.math_constant
HarfBuzz.math_italics_correction
HarfBuzz.math_top_accent_attachment
HarfBuzz.is_math_extended_shape
HarfBuzz.math_min_connector_overlap
HarfBuzz.math_glyph_variants
HarfBuzz.math_glyph_assembly
```

## Subsetting

```@docs
HarfBuzz.subset
```

## Unicode data

HarfBuzz ships its own Unicode tables — the ones shaping itself uses. They
are exposed so that code doing its own segmentation gets the same answers
the shaper did.

```@docs
HarfBuzz.script_of
HarfBuzz.general_category
HarfBuzz.combining_class
HarfBuzz.mirroring
HarfBuzz.compose
HarfBuzz.decompose
```
