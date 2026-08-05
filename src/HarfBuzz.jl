module HarfBuzz

using HarfBuzz_jll

const libhb = HarfBuzz_jll.libharfbuzz_path

# Nothing is exported: `Font`, `Face`, `Buffer` and `Blob` are far too
# generic to put in a user's namespace. Use the module instead:
#
#     import HarfBuzz as HB
#     font = HB.Font("DejaVu Sans"; size = 18)
#
# Set once the process starts shutting down. See `_font_destroy`.
const _EXITING = Ref(false)

function __init__()
    atexit(() -> _EXITING[] = true)
    return nothing
end

# --- Common helpers -------------------------------------------------------

# Pack a tag name into an `hb_tag_t`. Tags are exactly four bytes; shorter
# names are padded with spaces, longer ones are truncated, which is what
# `hb_tag_from_string` does.
function _name_to_tag(name::AbstractString)::UInt32
    bytes = codeunits(String(name))
    len = length(bytes)
    tag = UInt32(0)
    for i in 1:4
        c = i <= len ? bytes[i] : UInt8(' ')
        tag = (tag << 8) | UInt32(c)
    end
    return tag
end

function _tag_to_name(tag::UInt32)::String
    buf = Vector{UInt8}(undef, 5)
    ccall((:hb_tag_to_string, libhb), Cvoid, (UInt32, Ptr{UInt8}), tag, buf)
    return String(buf[1:4])
end

"""
    px(v) -> Float64

Convert a 26.6 fixed-point value -- the unit of every advance and offset
in a [`ShapeResult`](@ref) -- to pixels.

```julia
px(694)   # 10.84375
```
"""
px(v::Integer) = Float64(v) / 64

# --- Blob -----------------------------------------------------------------

"""
    Blob(path::AbstractString)
    Blob(data::AbstractVector{UInt8})

A chunk of binary data, usually the contents of a font file. `Blob` is the
bottom of HarfBuzz's object chain: a [`Face`](@ref) is created from a blob,
and a [`Font`](@ref) from a face.

Creating a blob from a Julia array does not copy it; the array is kept
alive by the blob.
"""
mutable struct Blob
    ptr::Ptr{Cvoid}
    # Anchor for Julia-owned bytes handed to HarfBuzz as READONLY.
    _data::Any
end

function _blob_destroy(b::Blob)
    b.ptr == C_NULL || ccall((:hb_blob_destroy, libhb), Cvoid, (Ptr{Cvoid},), b.ptr)
    b.ptr = C_NULL
    nothing
end

function Blob(path::AbstractString)
    ptr = ccall((:hb_blob_create_from_file_or_fail, libhb),
                Ptr{Cvoid}, (Cstring,), String(path))
    ptr == C_NULL && throw(ErrorException("cannot read font file: $path"))
    blob = Blob(ptr, nothing)
    finalizer(_blob_destroy, blob)
    return blob
end

const _HB_MEMORY_MODE_READONLY = Cint(1)

function Blob(data::AbstractVector{UInt8})
    bytes = data isa Vector{UInt8} ? data : collect(data)
    ptr = GC.@preserve bytes ccall(
        (:hb_blob_create_or_fail, libhb), Ptr{Cvoid},
        (Ptr{UInt8}, Cuint, Cint, Ptr{Cvoid}, Ptr{Cvoid}),
        pointer(bytes), Cuint(length(bytes)), _HB_MEMORY_MODE_READONLY,
        C_NULL, C_NULL)
    ptr == C_NULL && throw(ErrorException("hb_blob_create_or_fail failed"))
    blob = Blob(ptr, bytes)
    finalizer(_blob_destroy, blob)
    return blob
end

# `length(blob)` is the blob's size in bytes.
Base.length(b::Blob)::Int =
    Int(ccall((:hb_blob_get_length, libhb), Cuint, (Ptr{Cvoid},), b.ptr))

Base.isempty(b::Blob) = length(b) == 0

"""
    data(blob::Blob) -> Vector{UInt8}

Copy the blob's contents into a Julia array.
"""
function data(b::Blob)::Vector{UInt8}
    len = Ref{Cuint}(0)
    ptr = ccall((:hb_blob_get_data, libhb), Ptr{UInt8},
                (Ptr{Cvoid}, Ref{Cuint}), b.ptr, len)
    ptr == C_NULL && return UInt8[]
    return copy(unsafe_wrap(Array, ptr, Int(len[])))
end

"""
    face_count(blob::Blob) -> Int

Number of faces in the font file the blob holds. Greater than one for a
TrueType Collection (`.ttc`).
"""
face_count(b::Blob)::Int =
    Int(ccall((:hb_face_count, libhb), Cuint, (Ptr{Cvoid},), b.ptr))

# --- Face -----------------------------------------------------------------

"""
    Face(blob::Blob; index::Integer = 0)
    Face(path::AbstractString; index::Integer = 0)

A font face: the tables of one font inside a [`Blob`](@ref). `index`
selects the face inside a TrueType Collection.

A face carries no size; combine it with a size to get a [`Font`](@ref).
"""
mutable struct Face
    ptr::Ptr{Cvoid}
    # Anchor: the blob owns the bytes the face reads from.
    _blob::Any
end

function _face_destroy(f::Face)
    f.ptr == C_NULL || ccall((:hb_face_destroy, libhb), Cvoid, (Ptr{Cvoid},), f.ptr)
    f.ptr = C_NULL
    nothing
end

function Face(blob::Blob; index::Integer = 0)
    ptr = ccall((:hb_face_create, libhb), Ptr{Cvoid},
                (Ptr{Cvoid}, Cuint), blob.ptr, Cuint(index))
    ptr == C_NULL && throw(ErrorException("hb_face_create failed"))
    face = Face(ptr, blob)
    finalizer(_face_destroy, face)
    return face
end

Face(path::AbstractString; index::Integer = 0) = Face(Blob(path); index = index)

"""
    upem(face::Face) -> Int

Units per em: the design grid the face's outlines are expressed in,
typically 1000 (CFF) or 2048 (TrueType).
"""
upem(f::Face)::Int =
    Int(ccall((:hb_face_get_upem, libhb), Cuint, (Ptr{Cvoid},), f.ptr))

"""
    glyph_count(face::Face) -> Int

Number of glyphs in the face.
"""
glyph_count(f::Face)::Int =
    Int(ccall((:hb_face_get_glyph_count, libhb), Cuint, (Ptr{Cvoid},), f.ptr))

"""
    face_index(face::Face) -> Int

Index of this face inside its collection.
"""
face_index(f::Face)::Int =
    Int(ccall((:hb_face_get_index, libhb), Cuint, (Ptr{Cvoid},), f.ptr))

"""
    table_tags(face::Face) -> Vector{String}

The four-character tags of every table in the face, e.g. `"cmap"`,
`"GSUB"`, `"glyf"`.
"""
function table_tags(f::Face)::Vector{String}
    tags = String[]
    offset = Cuint(0)
    buf = Vector{UInt32}(undef, 32)
    while true
        count = Ref{Cuint}(length(buf))
        total = ccall((:hb_face_get_table_tags, libhb), Cuint,
                      (Ptr{Cvoid}, Cuint, Ref{Cuint}, Ptr{UInt32}),
                      f.ptr, offset, count, buf)
        n = Int(count[])
        n == 0 && break
        append!(tags, _tag_to_name(buf[i]) for i in 1:n)
        offset += Cuint(n)
        offset >= total && break
    end
    return tags
end

"""
    reference_table(face::Face, tag::AbstractString) -> Blob

The raw bytes of one table, as a blob. A table the face does not have
yields an empty blob rather than an error.
"""
function reference_table(f::Face, tag::AbstractString)::Blob
    ptr = ccall((:hb_face_reference_table, libhb), Ptr{Cvoid},
                (Ptr{Cvoid}, UInt32), f.ptr, _name_to_tag(tag))
    ptr == C_NULL && throw(ErrorException("hb_face_reference_table failed"))
    blob = Blob(ptr, nothing)
    finalizer(_blob_destroy, blob)
    return blob
end

# --- Font -----------------------------------------------------------------

"""
    Font(face::Face; size = nothing, scale = nothing, funcs = :ot)
    Font(path::AbstractString; size, index = 0, funcs = :ot)
    Font(family::AbstractString; size)

A face at a given size, ready to shape.

`size` is in pixels and sets the scale to `size * 64`, so advances and
offsets come back in 26.6 fixed point; use [`px`](@ref) to convert them.
`scale` sets the scale directly, in font units, and takes precedence.

`funcs` selects where glyph metrics come from:

- `:ot` (default) -- HarfBuzz reads the font tables itself. No FreeType.
- `:freetype` -- metrics come from FreeType, matching its hinting and
  rounding. Requires `using FreeType`, which loads the extension.

Passing a family name rather than a path requires
`using FreeTypeAbstraction`; such fonts are always FreeType-backed.

```julia
font = Font("/System/Library/Fonts/Menlo.ttc"; size = 18)
font = Font(face; scale = (2048, 2048))
```
"""
mutable struct Font
    ptr::Ptr{Cvoid}
    # Anchors: whatever the hb_font_t reads from must outlive it.
    _face::Any
    _backing::Any
end

function _font_destroy(f::Font)
    # Skip destruction at process teardown. Julia runs atexit hooks before
    # the final round of finalizers, and FreeTypeAbstraction's hook calls
    # FT_Done_FreeType, which frees every face its library owns. A
    # FreeType-backed hb_font_t would then call FT_Done_Face on freed
    # memory. Leaking here costs nothing -- the process is exiting.
    if f.ptr != C_NULL && !_EXITING[]
        ccall((:hb_font_destroy, libhb), Cvoid, (Ptr{Cvoid},), f.ptr)
    end
    f.ptr = C_NULL
    nothing
end

Font(face::Face; size = nothing, scale = nothing, funcs::Symbol = :ot) =
    _create_font(Val(funcs), face, size, scale)

# Backends apply this once the hb_font_t exists: an explicit `scale` wins,
# otherwise `size` pixels become 26.6 fixed point.
function _apply_scale!(font::Font, size, scale)
    if scale !== nothing
        scale!(font, scale)
    elseif size !== nothing
        s = round(Int, size * 64)
        scale!(font, (s, s))
    end
    return font
end

# Pixel size a backend should open its own face at.
_size_px(size, scale) =
    size !== nothing ? Float64(size) :
    scale !== nothing ? Float64(scale[1]) / 64 : 18.0

function Font(name::AbstractString; size = nothing, scale = nothing,
              index::Integer = 0, funcs::Symbol = :ot)
    if isfile(String(name))
        return Font(Face(String(name); index = index);
                    size = size, scale = scale, funcs = funcs)
    end
    return _resolve_family(String(name); size = size, scale = scale)
end

# `_create_font(::Val{:freetype}, ...)` is added by the FreeType
# extension; this is the fallback for every other backend name.
function _create_font(::Val{S}, ::Face, size, scale) where {S}
    S === :freetype && throw(ArgumentError(
        "the :freetype backend requires FreeType; add `using FreeType`"))
    throw(ArgumentError("unknown font funcs: :$S (expected :ot or :freetype)"))
end

function _create_font(::Val{:ot}, face::Face, size, scale)
    ptr = ccall((:hb_font_create, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), face.ptr)
    ptr == C_NULL && throw(ErrorException("hb_font_create failed"))
    ccall((:hb_ot_font_set_funcs, libhb), Cvoid, (Ptr{Cvoid},), ptr)
    font = Font(ptr, face, nothing)
    finalizer(_font_destroy, font)
    return _apply_scale!(font, size, scale)
end

# Set by the FreeTypeAbstraction extension. Resolving a family name needs
# a font database, which HarfBuzz does not provide.
const _FAMILY_RESOLVER = Ref{Any}(nothing)

function _resolve_family(name::AbstractString; kwargs...)
    resolver = _FAMILY_RESOLVER[]
    resolver === nothing && throw(ArgumentError(
        "'$name' is not a file, and resolving font family names requires " *
        "a font database; add `using FreeTypeAbstraction`"))
    return resolver(name; kwargs...)
end

"""
    scale(font::Font) -> Tuple{Int,Int}
    scale!(font::Font, (x, y))

Get or set the horizontal and vertical scale, in font units. Shaping
output is expressed in these units.
"""
function scale(f::Font)::Tuple{Int,Int}
    x = Ref{Cint}(0)
    y = Ref{Cint}(0)
    ccall((:hb_font_get_scale, libhb), Cvoid,
          (Ptr{Cvoid}, Ref{Cint}, Ref{Cint}), f.ptr, x, y)
    return (Int(x[]), Int(y[]))
end

function scale!(f::Font, xy::Tuple{Integer,Integer})::Font
    ccall((:hb_font_set_scale, libhb), Cvoid,
          (Ptr{Cvoid}, Cint, Cint), f.ptr, Cint(xy[1]), Cint(xy[2]))
    return f
end

"""
    ppem(font::Font) -> Tuple{Int,Int}
    ppem!(font::Font, (x, y))

Get or set the horizontal and vertical pixels-per-em, used by fonts that
carry bitmap strikes or size-specific hinting.
"""
function ppem(f::Font)::Tuple{Int,Int}
    x = Ref{Cuint}(0)
    y = Ref{Cuint}(0)
    ccall((:hb_font_get_ppem, libhb), Cvoid,
          (Ptr{Cvoid}, Ref{Cuint}, Ref{Cuint}), f.ptr, x, y)
    return (Int(x[]), Int(y[]))
end

function ppem!(f::Font, xy::Tuple{Integer,Integer})::Font
    ccall((:hb_font_set_ppem, libhb), Cvoid,
          (Ptr{Cvoid}, Cuint, Cuint), f.ptr, Cuint(xy[1]), Cuint(xy[2]))
    return f
end

"""
    ptem(font::Font) -> Float64
    ptem!(font::Font, points)

Get or set the point size, which fonts with an optical size axis use to
pick an optical variant. Zero means unset.
"""
ptem(f::Font)::Float64 =
    Float64(ccall((:hb_font_get_ptem, libhb), Cfloat, (Ptr{Cvoid},), f.ptr))

function ptem!(f::Font, points::Real)::Font
    ccall((:hb_font_set_ptem, libhb), Cvoid,
          (Ptr{Cvoid}, Cfloat), f.ptr, Cfloat(points))
    return f
end

# --- Buffer ---------------------------------------------------------------

"""
    Buffer()

Create an empty buffer. Add text with [`add_text!`](@ref), then call
[`shape!`](@ref).
"""
mutable struct Buffer
    ptr::Ptr{Cvoid}
end

function _buffer_destroy(b::Buffer)
    b.ptr == C_NULL || ccall((:hb_buffer_destroy, libhb), Cvoid, (Ptr{Cvoid},), b.ptr)
    b.ptr = C_NULL
    nothing
end

function Buffer()::Buffer
    ptr = ccall((:hb_buffer_create, libhb), Ptr{Cvoid}, ())
    ptr == C_NULL && throw(ErrorException("hb_buffer_create failed"))
    buf = Buffer(ptr)
    finalizer(_buffer_destroy, buf)
    return buf
end

"""
    clear!(buf::Buffer)

Reset the buffer to empty, discarding all content and state.
"""
function clear!(buf::Buffer)::Nothing
    ccall((:hb_buffer_clear_contents, libhb), Cvoid, (Ptr{Cvoid},), buf.ptr)
    return nothing
end

"""
    add_text!(buf::Buffer, text::AbstractString)

Add UTF-8 text to the buffer.
"""
function add_text!(buf::Buffer, text::AbstractString)::Nothing
    bytes = codeunits(String(text))
    n = length(bytes)
    GC.@preserve bytes begin
        ccall((:hb_buffer_add_utf8, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{UInt8}, Cint, Cuint, Cint),
              buf.ptr, pointer(bytes), Cint(n), Cuint(0), Cint(-1))
    end
    return nothing
end

"""
    guess_segment_properties!(buf::Buffer)

Ask HarfBuzz to guess script, language and direction from the buffer
content.
"""
function guess_segment_properties!(buf::Buffer)::Nothing
    ccall((:hb_buffer_guess_segment_properties, libhb), Cvoid,
          (Ptr{Cvoid},), buf.ptr)
    return nothing
end

# --- Shaping result -------------------------------------------------------

"""
    GlyphInfo

Per-glyph output from shaping. Fields:

- `glyph_id::UInt32` — glyph ID in the font.
- `cluster::UInt32` — byte offset of the originating cluster in the
  input UTF-8 text.
"""
struct GlyphInfo
    glyph_id::UInt32
    cluster::UInt32
end

"""
    GlyphPosition

Per-glyph position from shaping. All fields are in the font's scale units,
which [`Font`](@ref)'s `size` argument sets to 26.6 fixed point (1/64 px);
convert with [`px`](@ref). Fields:

- `x_advance::Int32`, `y_advance::Int32` — advance to the next glyph.
- `x_offset::Int32`, `y_offset::Int32` — offset from the pen position.
"""
struct GlyphPosition
    x_advance::Int32
    y_advance::Int32
    x_offset::Int32
    y_offset::Int32
end

"""
    ShapeResult

Result of [`shape`](@ref) / [`shape!`](@ref). Fields:

- `infos::Vector{GlyphInfo}` — one entry per output glyph.
- `positions::Vector{GlyphPosition}` — parallel to `infos`.
"""
struct ShapeResult
    infos::Vector{GlyphInfo}
    positions::Vector{GlyphPosition}
end

# Mirrors of the C layouts. Declaring them lets Julia compute the stride
# instead of hard-coding it -- `hb_glyph_position_t` is 20 bytes, not 24,
# and getting that wrong zeroes every entry after the first.
struct _HbGlyphInfoRaw
    codepoint::UInt32
    mask::UInt32
    cluster::UInt32
    var1::UInt32
    var2::UInt32
end

struct _HbGlyphPositionRaw
    x_advance::Int32
    y_advance::Int32
    x_offset::Int32
    y_offset::Int32
    var::UInt32
end

"""
    Feature

An OpenType feature to apply while shaping: a 4-byte `tag`, a `value`
(0 disables, 1 enables, higher values select an alternate), and the
half-open buffer range `[start, stop)` it applies to.
"""
struct Feature
    tag::UInt32
    value::UInt32
    start::UInt32
    stop::UInt32
end

# `hb_feature_t` uses these to mean "the whole buffer". A `stop` of 0 is
# an empty range, which silently turns the feature into a no-op.
const HB_FEATURE_GLOBAL_START = UInt32(0)
const HB_FEATURE_GLOBAL_END = typemax(UInt32)

_make_feature(name::AbstractString, value::Integer) =
    Feature(_name_to_tag(name), UInt32(value),
            HB_FEATURE_GLOBAL_START, HB_FEATURE_GLOBAL_END)

"""
    shape!(font::Font, buf::Buffer; features=nothing)

Shape the text in `buf` using `font`. Returns a `ShapeResult` with
glyph infos and positions.
"""
function shape!(font::Font, buf::Buffer;
                features::Union{Nothing,Vector{Tuple{String,Int}}} = nothing)::ShapeResult
    if features === nothing
        ccall((:hb_shape, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cuint),
              font.ptr, buf.ptr, C_NULL, Cuint(0))
    else
        nfeat = length(features)
        feat_arr = [_make_feature(name, val) for (name, val) in features]
        GC.@preserve feat_arr begin
            ccall((:hb_shape, libhb), Cvoid,
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cuint),
                  font.ptr, buf.ptr, pointer(feat_arr), Cuint(nfeat))
        end
    end

    n_info = Ref{Cuint}(0)
    info_ptr = ccall((:hb_buffer_get_glyph_infos, libhb),
                     Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Cuint}), buf.ptr, n_info)
    n = Int(n_info[])

    n_pos = Ref{Cuint}(0)
    pos_ptr = ccall((:hb_buffer_get_glyph_positions, libhb),
                    Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Cuint}), buf.ptr, n_pos)
    @assert n == Int(n_pos[]) "glyph info/position count mismatch"

    # The arrays below are owned by the buffer; copy out of them so the
    # result stays valid after the next shape!/clear! or once the buffer
    # is finalized.
    raw_infos = unsafe_wrap(Array, convert(Ptr{_HbGlyphInfoRaw}, info_ptr), n)
    infos = [GlyphInfo(r.codepoint, r.cluster) for r in raw_infos]

    raw_positions = unsafe_wrap(Array,
                                convert(Ptr{_HbGlyphPositionRaw}, pos_ptr), n)
    positions = [GlyphPosition(r.x_advance, r.y_advance, r.x_offset, r.y_offset)
                 for r in raw_positions]

    return ShapeResult(infos, positions)
end

"""
    shape(font::Font, text::AbstractString; features=nothing) -> ShapeResult

One-shot convenience: create a buffer, add text, guess segment
properties, shape, and return the result.

```julia
result = shape(font, "Hello")
result = shape(font, "AVATAR"; features = [("kern", 0)])
```
"""
function shape(font::Font, text::AbstractString;
               features::Union{Nothing,Vector{Tuple{String,Int}}} = nothing)::ShapeResult
    buf = Buffer()
    add_text!(buf, text)
    guess_segment_properties!(buf)
    result = shape!(font, buf; features = features)
    return result
end

"""
    glyph_ids(result::ShapeResult) -> Vector{UInt32}

Return the glyph IDs from a `ShapeResult`.
"""
glyph_ids(result::ShapeResult) = [g.glyph_id for g in result.infos]

"""
    clusters(result::ShapeResult) -> Vector{UInt32}

Return the cluster indices from a `ShapeResult`. Each cluster index
corresponds to the byte offset in the original UTF-8 input string of the
glyph sequence it belongs to.
"""
clusters(result::ShapeResult) = [g.cluster for g in result.infos]

# --- Font queries ---------------------------------------------------------

"""
    get_nominal_glyph(font::Font, unicode::UInt32) -> UInt32

Return the glyph ID for a Unicode codepoint, or 0 if the font does
not contain it.
"""
function get_nominal_glyph(font::Font, unicode::UInt32)::UInt32
    glyph = Ref{UInt32}(0)
    found = ccall((:hb_font_get_glyph, libhb), Cint,
                  (Ptr{Cvoid}, UInt32, UInt32, Ref{UInt32}),
                  font.ptr, unicode, UInt32(0), glyph)
    return found != 0 ? glyph[] : UInt32(0)
end

"""
    has_glyph(font::Font, unicode::UInt32) -> Bool

True if the font contains a glyph for `unicode`.
"""
has_glyph(font::Font, unicode::UInt32)::Bool = get_nominal_glyph(font, unicode) != 0

end # module
