# Font queries

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
```

## Font size and metrics state

`scale`, `ppem` and `ptem` each have a setter suffixed with `!`
(`scale!`, `ppem!`, `ptem!`).

```@docs
HarfBuzz.scale
HarfBuzz.ppem
HarfBuzz.ptem
```

## Glyph availability

```@docs
HarfBuzz.has_glyph
HarfBuzz.get_nominal_glyph
```
