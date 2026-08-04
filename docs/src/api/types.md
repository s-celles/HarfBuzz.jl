# Types

## Opaque handles

```@docs
HarfBuzz.HbBlob
HarfBuzz.HbFace
HarfBuzz.HbFont
HarfBuzz.HbBuffer
```

## Result types

```@docs
HarfBuzz.GlyphInfo
HarfBuzz.GlyphPosition
HarfBuzz.ShapeResult
```

## Constructors

```@docs
HarfBuzz.HbBlob
HarfBuzz.HbFace(::HarfBuzz.HbBlob, ::Integer)
HarfBuzz.HbFace(::AbstractString, ::Integer)
HarfBuzz.HbFont(::HarfBuzz.HbFace; kwargs...)
HarfBuzz.HbFont(::HarfBuzz.HbFace, ::Integer)
HarfBuzz.HbFont(::AbstractString, ::Integer)
HarfBuzz.HbBuffer
```