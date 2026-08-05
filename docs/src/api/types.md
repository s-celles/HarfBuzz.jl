# Types

Nothing is exported: `Font`, `Face`, `Buffer` and `Blob` are far too
generic to place in your namespace. Reach them through the module.

```julia
import HarfBuzz as HB

face = HB.Face("/System/Library/Fonts/Menlo.ttc")
font = HB.Font(face; size = 18)
```

## Object chain

HarfBuzz stacks three objects: a `Blob` holds bytes, a `Face` interprets
them as font tables, and a `Font` fixes a size. Each keeps the one below
it alive, so a `Font` built straight from a path is self-sufficient.

```@docs
HarfBuzz.Blob
HarfBuzz.Face
HarfBuzz.Font
```

## Buffers

```@docs
HarfBuzz.Buffer
```

## Result types

```@docs
HarfBuzz.GlyphInfo
HarfBuzz.GlyphPosition
HarfBuzz.ShapeResult
HarfBuzz.Feature
```
