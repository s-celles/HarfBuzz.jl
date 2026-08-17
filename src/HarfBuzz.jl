module HarfBuzz

using HarfBuzz_jll
using Libdl

const libhb = HarfBuzz_jll.libharfbuzz_path

# Nothing is exported: `Font`, `Face`, `Buffer` and `Blob` are far too
# generic to put in a user's namespace. Use the module instead:
#
#     import HarfBuzz as HB
#     font = HB.Font("/path/to/DejaVuSans.ttf"; size = 18)
#
# Set once the process starts shutting down. See `_font_destroy`.
const _EXITING = Ref(false)

# `__init__` is defined at the end of the module: it needs the message
# trampoline, and @cfunction resolves it when this file is compiled.

# --- Library -------------------------------------------------------------

"""
    version() -> VersionNumber

Version of the HarfBuzz library being called.
"""
function version()::VersionNumber
    major = Ref{Cuint}(0)
    minor = Ref{Cuint}(0)
    micro = Ref{Cuint}(0)
    ccall((:hb_version, libhb), Cvoid,
          (Ref{Cuint}, Ref{Cuint}, Ref{Cuint}), major, minor, micro)
    return VersionNumber(Int(major[]), Int(minor[]), Int(micro[]))
end

"""
    version_string() -> String

Version of the HarfBuzz library as it reports it.
"""
version_string()::String =
    unsafe_string(ccall((:hb_version_string, libhb), Cstring, ()))

"""
    shapers() -> Vector{String}

Names of the shaping backends this build supports, in the order HarfBuzz
would try them. `"ot"` is the OpenType shaper and is always present.
"""
function shapers()::Vector{String}
    ptr = ccall((:hb_shape_list_shapers, libhb), Ptr{Ptr{UInt8}}, ())
    ptr == C_NULL && return String[]
    names = String[]
    i = 1
    while true
        s = unsafe_load(ptr, i)
        s == C_NULL && break
        push!(names, unsafe_string(s))
        i += 1
    end
    return names
end

# --- Tags -----------------------------------------------------------------

"""
    tag(name::AbstractString) -> UInt32

Pack a four-character tag such as `"kern"` or `"GSUB"` into an `hb_tag_t`.
Shorter names are padded with spaces, longer ones are truncated.
"""
tag(name::AbstractString)::UInt32 =
    ccall((:hb_tag_from_string, libhb), UInt32,
          (Ptr{UInt8}, Cint), String(name), Cint(sizeof(name)))

"""
    tag_string(t::UInt32) -> String

The four characters of a tag.
"""
function tag_string(t::UInt32)::String
    buf = Vector{UInt8}(undef, 4)
    ccall((:hb_tag_to_string, libhb), Cvoid, (UInt32, Ptr{UInt8}), t, buf)
    return String(buf)
end

# --- Direction, script, language -----------------------------------------

const _DIRECTIONS = (:invalid, :ltr, :rtl, :ttb, :btt)

# hb_direction_t: invalid is 0, the real directions start at 4.
_direction_symbol(d::Integer) =
    d == 0 ? :invalid : 4 <= d <= 7 ? _DIRECTIONS[d - 2] : :invalid

function _direction_value(s::Symbol)::Cint
    s === :invalid && return Cint(0)
    i = findfirst(==(s), _DIRECTIONS)
    i === nothing && throw(ArgumentError(
        "unknown direction :$s (expected one of $(join(_DIRECTIONS, ", "))"))
    return Cint(i + 2)
end

_script_symbol(s::UInt32) = Symbol(strip(tag_string(
    ccall((:hb_script_to_iso15924_tag, libhb), UInt32, (UInt32,), s))))

_script_value(s::Symbol)::UInt32 =
    ccall((:hb_script_from_string, libhb), UInt32,
          (Ptr{UInt8}, Cint), String(s), Cint(sizeof(String(s))))

_language_value(s::AbstractString)::Ptr{Cvoid} =
    ccall((:hb_language_from_string, libhb), Ptr{Cvoid},
          (Ptr{UInt8}, Cint), String(s), Cint(sizeof(s)))

function _language_symbol(l::Ptr{Cvoid})::String
    l == C_NULL && return ""
    s = ccall((:hb_language_to_string, libhb), Cstring, (Ptr{Cvoid},), l)
    return s == C_NULL ? "" : unsafe_string(s)
end

# Turn a Symbol -> bit mapping (a tuple of pairs, so it stays ordered and
# allocation-free) into a flag word, and back.
function _flags_value(names, mapping, what)::UInt32
    v = UInt32(0)
    for n in names
        i = findfirst(p -> p.first === n, mapping)
        i === nothing && throw(ArgumentError(
            "unknown $what :$n (expected one of " *
            join(map(p -> ":" * String(p.first), mapping), ", ") * ")"))
        v |= mapping[i].second
    end
    return v
end

_flags_symbols(v::Integer, mapping) =
    Symbol[p.first for p in mapping if v & p.second != 0]

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
        append!(tags, tag_string(buf[i]) for i in 1:n)
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
function reference_table(f::Face, name::AbstractString)::Blob
    ptr = ccall((:hb_face_reference_table, libhb), Ptr{Cvoid},
                (Ptr{Cvoid}, UInt32), f.ptr, tag(name))
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

`path` must be a font file. HarfBuzz has no font database, and neither
does this package: resolve family names with Fontconfig.jl,
FreeTypeAbstraction.jl or a platform API, then pass the path.

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

function Font(path::AbstractString; size = nothing, scale = nothing,
              index::Integer = 0, funcs::Symbol = :ot)
    isfile(String(path)) || throw(ArgumentError(
        "$(repr(String(path))) is not a file. HarfBuzz has no font " *
        "database and neither does this package: pass a path to a font " *
        "file, or resolve the family name yourself (Fontconfig.jl, " *
        "FreeTypeAbstraction.jl, or a platform API)."))
    return Font(Face(String(path); index = index);
                size = size, scale = scale, funcs = funcs)
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
    # Anchor for the callback installed by `message_func!`.
    _message::Any
end

function _buffer_destroy(b::Buffer)
    b.ptr == C_NULL || ccall((:hb_buffer_destroy, libhb), Cvoid, (Ptr{Cvoid},), b.ptr)
    b.ptr = C_NULL
    nothing
end

function Buffer()::Buffer
    ptr = ccall((:hb_buffer_create, libhb), Ptr{Cvoid}, ())
    ptr == C_NULL && throw(ErrorException("hb_buffer_create failed"))
    buf = Buffer(ptr, nothing)
    finalizer(_buffer_destroy, buf)
    return buf
end

"""
    clear!(buf::Buffer)

Empty the buffer's contents, keeping direction, script, language and
flags. Use [`reset!`](@ref) to drop those too.
"""
function clear!(buf::Buffer)::Nothing
    ccall((:hb_buffer_clear_contents, libhb), Cvoid, (Ptr{Cvoid},), buf.ptr)
    return nothing
end

"""
    reset!(buf::Buffer)

Return the buffer to its initial state: empty, with no direction, script,
language or flags set.
"""
function reset!(buf::Buffer)::Nothing
    ccall((:hb_buffer_reset, libhb), Cvoid, (Ptr{Cvoid},), buf.ptr)
    return nothing
end

# `length(buf)` is the number of items -- codepoints before shaping,
# glyphs after.
Base.length(b::Buffer)::Int =
    Int(ccall((:hb_buffer_get_length, libhb), Cuint, (Ptr{Cvoid},), b.ptr))

Base.isempty(b::Buffer) = length(b) == 0

"""
    add_text!(buf::Buffer, text::AbstractString;
              item_offset = 0, item_length = -1)

Add UTF-8 text to the buffer.

The whole string is always visible to the shaper as context, but only the
bytes in `[item_offset, item_offset + item_length)` become items to shape.
`item_length = -1` means "to the end". Supplying context matters for
scripts whose glyphs depend on their neighbours, such as Arabic: shaping a
run without it produces the wrong contextual forms at the boundaries.

Offsets are in **bytes**, matching the cluster values shaping returns.
"""
function add_text!(buf::Buffer, text::AbstractString;
                   item_offset::Integer = 0, item_length::Integer = -1)::Nothing
    bytes = codeunits(String(text))
    n = length(bytes)
    GC.@preserve bytes begin
        ccall((:hb_buffer_add_utf8, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{UInt8}, Cint, Cuint, Cint),
              buf.ptr, pointer(bytes), Cint(n),
              Cuint(item_offset), Cint(item_length))
    end
    _check_allocation(buf)
    return nothing
end

"""
    add_codepoints!(buf::Buffer, codepoints;
                    item_offset = 0, item_length = -1)

Add Unicode codepoints directly, bypassing UTF-8 decoding. Use this when
the input is already decoded, or to feed HarfBuzz codepoints that are not
valid on their own.
"""
function add_codepoints!(buf::Buffer, codepoints::AbstractVector{UInt32};
                         item_offset::Integer = 0,
                         item_length::Integer = -1)::Nothing
    cps = codepoints isa Vector{UInt32} ? codepoints : collect(codepoints)
    GC.@preserve cps begin
        ccall((:hb_buffer_add_codepoints, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{UInt32}, Cint, Cuint, Cint),
              buf.ptr, pointer(cps), Cint(length(cps)),
              Cuint(item_offset), Cint(item_length))
    end
    _check_allocation(buf)
    return nothing
end

# `append!(dest, src)` appends src's contents to dest.
function Base.append!(dest::Buffer, src::Buffer)
    ccall((:hb_buffer_append, libhb), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Cuint, Cuint),
          dest.ptr, src.ptr, Cuint(0), Cuint(length(src)))
    _check_allocation(dest)
    return dest
end

# `reverse!(buf)` reverses the buffer's contents.
function Base.reverse!(buf::Buffer)
    ccall((:hb_buffer_reverse, libhb), Cvoid, (Ptr{Cvoid},), buf.ptr)
    return buf
end

"""
    reverse_clusters!(buf::Buffer)

Reverse the buffer's contents, then reverse each cluster back, so cluster
contents keep their order.
"""
function reverse_clusters!(buf::Buffer)
    ccall((:hb_buffer_reverse_clusters, libhb), Cvoid, (Ptr{Cvoid},), buf.ptr)
    return buf
end

"""
    pre_allocate!(buf::Buffer, size) -> Bool

Reserve room for `size` items up front. Returns `false` if the allocation
failed.
"""
pre_allocate!(buf::Buffer, size::Integer)::Bool =
    ccall((:hb_buffer_pre_allocate, libhb), Cint,
          (Ptr{Cvoid}, Cuint), buf.ptr, Cuint(size)) != 0

"""
    allocation_successful(buf::Buffer) -> Bool

`false` once any allocation on this buffer has failed, which makes every
later result unreliable.
"""
allocation_successful(buf::Buffer)::Bool =
    ccall((:hb_buffer_allocation_successful, libhb), Cint,
          (Ptr{Cvoid},), buf.ptr) != 0

function _check_allocation(buf::Buffer)
    allocation_successful(buf) ||
        throw(OutOfMemoryError())
    return nothing
end

# --- Buffer properties ----------------------------------------------------

"""
    direction(buf::Buffer) -> Symbol
    direction!(buf::Buffer, dir::Symbol)

Text flow direction: `:ltr`, `:rtl`, `:ttb`, `:btt`, or `:invalid` when
unset. [`guess_segment_properties!`](@ref) can infer it from the content.
"""
direction(buf::Buffer)::Symbol = _direction_symbol(
    ccall((:hb_buffer_get_direction, libhb), Cint, (Ptr{Cvoid},), buf.ptr))

function direction!(buf::Buffer, dir::Symbol)
    ccall((:hb_buffer_set_direction, libhb), Cvoid,
          (Ptr{Cvoid}, Cint), buf.ptr, _direction_value(dir))
    return buf
end

"""
    script(buf::Buffer) -> Symbol
    script!(buf::Buffer, s::Symbol)

Writing system, as an ISO 15924 tag such as `:Latn`, `:Arab` or `:Hani`.
"""
script(buf::Buffer)::Symbol = _script_symbol(
    ccall((:hb_buffer_get_script, libhb), UInt32, (Ptr{Cvoid},), buf.ptr))

function script!(buf::Buffer, s::Symbol)
    ccall((:hb_buffer_set_script, libhb), Cvoid,
          (Ptr{Cvoid}, UInt32), buf.ptr, _script_value(s))
    return buf
end

"""
    language(buf::Buffer) -> String
    language!(buf::Buffer, tag::AbstractString)

BCP 47 language tag, e.g. `"en"`, `"fr"`, `"sr-latn"`. Some features are
language-specific.
"""
language(buf::Buffer)::String = _language_symbol(
    ccall((:hb_buffer_get_language, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), buf.ptr))

function language!(buf::Buffer, name::AbstractString)
    ccall((:hb_buffer_set_language, libhb), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}), buf.ptr, _language_value(name))
    return buf
end

"""
    segment_properties(buf::Buffer) -> NamedTuple
    segment_properties!(buf::Buffer, props::NamedTuple)

Read or set direction, script and language together. Any key left out of
`props` is untouched.

```julia
segment_properties!(buf, (direction = :rtl, script = :Arab, language = "ar"))
```
"""
segment_properties(buf::Buffer) =
    (direction = direction(buf), script = script(buf), language = language(buf))

function segment_properties!(buf::Buffer, props::NamedTuple)
    haskey(props, :direction) && direction!(buf, props.direction)
    haskey(props, :script) && script!(buf, props.script)
    haskey(props, :language) && language!(buf, props.language)
    return buf
end

const _BUFFER_FLAGS = (
    :bot => UInt32(0x0001),
    :eot => UInt32(0x0002),
    :preserve_default_ignorables => UInt32(0x0004),
    :remove_default_ignorables => UInt32(0x0008),
    :do_not_insert_dotted_circle => UInt32(0x0010),
    :verify => UInt32(0x0020),
    :produce_unsafe_to_concat => UInt32(0x0040),
    :produce_safe_to_insert_tatweel => UInt32(0x0080),
)

"""
    flags(buf::Buffer) -> Vector{Symbol}
    flags!(buf::Buffer, names)

Buffer flags, as symbols. `:bot` and `:eot` tell the shaper the run is at
the beginning or end of a paragraph, which affects contextual forms.
`:produce_unsafe_to_concat` makes shaping report the extra glyph flag of
the same name.

Available: $(join(map(p -> ":" * String(p.first), _BUFFER_FLAGS), ", ")).
"""
flags(buf::Buffer)::Vector{Symbol} = _flags_symbols(
    ccall((:hb_buffer_get_flags, libhb), Cuint, (Ptr{Cvoid},), buf.ptr),
    _BUFFER_FLAGS)

function flags!(buf::Buffer, names)
    ccall((:hb_buffer_set_flags, libhb), Cvoid, (Ptr{Cvoid}, Cuint),
          buf.ptr, _flags_value(names, _BUFFER_FLAGS, "buffer flag"))
    return buf
end

const _CLUSTER_LEVELS = (:monotone_graphemes, :monotone_characters, :characters)

"""
    cluster_level(buf::Buffer) -> Symbol
    cluster_level!(buf::Buffer, level::Symbol)

How finely shaping reports clusters: `:monotone_graphemes` (the default,
clusters never decrease and whole graphemes stay together),
`:monotone_characters`, or `:characters` (the finest, clusters may be in
any order).
"""
function cluster_level(buf::Buffer)::Symbol
    v = ccall((:hb_buffer_get_cluster_level, libhb), Cint, (Ptr{Cvoid},), buf.ptr)
    return 0 <= v <= 2 ? _CLUSTER_LEVELS[v + 1] : :monotone_graphemes
end

function cluster_level!(buf::Buffer, level::Symbol)
    i = findfirst(==(level), _CLUSTER_LEVELS)
    i === nothing && throw(ArgumentError(
        "unknown cluster level :$level (expected one of " *
        "$(join(_CLUSTER_LEVELS, ", ")))"))
    ccall((:hb_buffer_set_cluster_level, libhb), Cvoid,
          (Ptr{Cvoid}, Cint), buf.ptr, Cint(i - 1))
    return buf
end

const _CONTENT_TYPES = (:invalid, :unicode, :glyphs)

"""
    content_type(buf::Buffer) -> Symbol

What the buffer holds: `:invalid` when empty, `:unicode` after adding
text, `:glyphs` after shaping.
"""
function content_type(buf::Buffer)::Symbol
    v = ccall((:hb_buffer_get_content_type, libhb), Cint, (Ptr{Cvoid},), buf.ptr)
    return 0 <= v <= 2 ? _CONTENT_TYPES[v + 1] : :invalid
end

"""
    replacement_codepoint(buf::Buffer) -> UInt32
    replacement_codepoint!(buf::Buffer, cp)

Codepoint substituted for input bytes that are not valid UTF-8.
"""
replacement_codepoint(buf::Buffer)::UInt32 =
    ccall((:hb_buffer_get_replacement_codepoint, libhb), UInt32,
          (Ptr{Cvoid},), buf.ptr)

function replacement_codepoint!(buf::Buffer, cp::Integer)
    ccall((:hb_buffer_set_replacement_codepoint, libhb), Cvoid,
          (Ptr{Cvoid}, UInt32), buf.ptr, UInt32(cp))
    return buf
end

"""
    invisible_glyph(buf::Buffer) -> UInt32
    invisible_glyph!(buf::Buffer, gid)

Glyph used for characters that should take space but draw nothing. Zero
means the font's own space glyph.
"""
invisible_glyph(buf::Buffer)::UInt32 =
    ccall((:hb_buffer_get_invisible_glyph, libhb), UInt32, (Ptr{Cvoid},), buf.ptr)

function invisible_glyph!(buf::Buffer, gid::Integer)
    ccall((:hb_buffer_set_invisible_glyph, libhb), Cvoid,
          (Ptr{Cvoid}, UInt32), buf.ptr, UInt32(gid))
    return buf
end

"""
    not_found_glyph(buf::Buffer) -> UInt32
    not_found_glyph!(buf::Buffer, gid)

Glyph used for characters the font has no glyph for. Zero is `.notdef`.
"""
not_found_glyph(buf::Buffer)::UInt32 =
    ccall((:hb_buffer_get_not_found_glyph, libhb), UInt32, (Ptr{Cvoid},), buf.ptr)

function not_found_glyph!(buf::Buffer, gid::Integer)
    ccall((:hb_buffer_set_not_found_glyph, libhb), Cvoid,
          (Ptr{Cvoid}, UInt32), buf.ptr, UInt32(gid))
    return buf
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

- `glyph_id::UInt32` — glyph ID in the font. Before shaping this is the
  input codepoint instead.
- `cluster::UInt32` — byte offset of the originating cluster in the
  input UTF-8 text.
- `flags::UInt32` — see [`unsafe_to_break`](@ref) and
  [`unsafe_to_concat`](@ref).
"""
struct GlyphInfo
    glyph_id::UInt32
    cluster::UInt32
    flags::UInt32
end

const HB_GLYPH_FLAG_UNSAFE_TO_BREAK = UInt32(0x0001)
const HB_GLYPH_FLAG_UNSAFE_TO_CONCAT = UInt32(0x0002)
const HB_GLYPH_FLAG_SAFE_TO_INSERT_TATWEEL = UInt32(0x0004)
const HB_GLYPH_FLAG_DEFINED = UInt32(0x0007)

"""
    unsafe_to_break(info::GlyphInfo) -> Bool

True when breaking the text at the start of this glyph's cluster would
change the shaping result, so both halves would need reshaping. This is
what a line breaker must consult before splitting a shaped run.
"""
unsafe_to_break(i::GlyphInfo)::Bool =
    i.flags & HB_GLYPH_FLAG_UNSAFE_TO_BREAK != 0

"""
    unsafe_to_concat(info::GlyphInfo) -> Bool

True when this glyph's cluster cannot be concatenated with what precedes
or follows without reshaping. Only reported when the buffer carries the
`:produce_unsafe_to_concat` flag.
"""
unsafe_to_concat(i::GlyphInfo)::Bool =
    i.flags & HB_GLYPH_FLAG_UNSAFE_TO_CONCAT != 0

"""
    safe_to_insert_tatweel(info::GlyphInfo) -> Bool

True when an Arabic tatweel may be inserted at this position without
changing the shaping. Only reported when the buffer carries the
`:produce_safe_to_insert_tatweel` flag.
"""
safe_to_insert_tatweel(i::GlyphInfo)::Bool =
    i.flags & HB_GLYPH_FLAG_SAFE_TO_INSERT_TATWEEL != 0

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

# --- Reading a buffer's contents ------------------------------------------

"""
    glyph_infos(buf::Buffer) -> Vector{GlyphInfo}

The buffer's per-item information. Before shaping, `glyph_id` holds the
input codepoint; after shaping, the glyph ID.
"""
function glyph_infos(buf::Buffer)::Vector{GlyphInfo}
    n = Ref{Cuint}(0)
    ptr = ccall((:hb_buffer_get_glyph_infos, libhb),
                Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Cuint}), buf.ptr, n)
    ptr == C_NULL && return GlyphInfo[]
    raw = unsafe_wrap(Array, convert(Ptr{_HbGlyphInfoRaw}, ptr), Int(n[]))
    return [GlyphInfo(r.codepoint, r.cluster, r.mask & HB_GLYPH_FLAG_DEFINED)
            for r in raw]
end

"""
    glyph_positions(buf::Buffer) -> Vector{GlyphPosition}

The buffer's per-glyph positions. Only meaningful after shaping.
"""
function glyph_positions(buf::Buffer)::Vector{GlyphPosition}
    n = Ref{Cuint}(0)
    ptr = ccall((:hb_buffer_get_glyph_positions, libhb),
                Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Cuint}), buf.ptr, n)
    ptr == C_NULL && return GlyphPosition[]
    raw = unsafe_wrap(Array, convert(Ptr{_HbGlyphPositionRaw}, ptr), Int(n[]))
    return [GlyphPosition(r.x_advance, r.y_advance, r.x_offset, r.y_offset)
            for r in raw]
end

"""
    codepoints(buf::Buffer) -> Vector{UInt32}

The buffer's input codepoints, before shaping replaces them with glyph
IDs.
"""
codepoints(buf::Buffer)::Vector{UInt32} = [i.glyph_id for i in glyph_infos(buf)]

"""
    has_positions(buf::Buffer) -> Bool

True once shaping has filled in position data.
"""
has_positions(buf::Buffer)::Bool =
    ccall((:hb_buffer_has_positions, libhb), Cint, (Ptr{Cvoid},), buf.ptr) != 0

# --- Features -------------------------------------------------------------

"""
    Feature(tag, value, start, stop)
    Feature(spec::AbstractString)

An OpenType feature to apply while shaping: a 4-byte `tag`, a `value`
(0 disables, 1 enables, higher values select an alternate), and the
half-open buffer range `[start, stop)` it applies to.

The string form is HarfBuzz's own syntax, the same one `hb-shape
--features` takes:

```julia
Feature("kern")         # kern=1, whole buffer
Feature("-liga")        # liga=0
Feature("aalt[3:5]=2")  # aalt=2, over items 3 to 5
```
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
    Feature(tag(name), UInt32(value),
            HB_FEATURE_GLOBAL_START, HB_FEATURE_GLOBAL_END)

function Feature(spec::AbstractString)
    out = Ref{Feature}()
    ok = ccall((:hb_feature_from_string, libhb), Cint,
               (Ptr{UInt8}, Cint, Ref{Feature}),
               String(spec), Cint(sizeof(spec)), out)
    ok == 0 && throw(ArgumentError("cannot parse feature: $(repr(spec))"))
    return out[]
end

function Base.string(f::Feature)
    buf = Vector{UInt8}(undef, 128)
    ccall((:hb_feature_to_string, libhb), Cvoid,
          (Ref{Feature}, Ptr{UInt8}, Cuint), Ref(f), buf, Cuint(length(buf)))
    stop = findfirst(==(0x00), buf)
    return String(buf[1:(stop === nothing ? length(buf) : stop - 1)])
end

Base.show(io::IO, f::Feature) = print(io, "Feature(\"", string(f), "\")")

# The three accepted spellings in `features = [...]`. Deliberately not
# accepted: `Dict` (unordered, and HarfBuzz applies features in order,
# last one winning for a tag) and `NamedTuple` (unique keys), because
# neither can express a range or the same tag applied twice.
_as_feature(f::Feature) = f
_as_feature(s::AbstractString) = Feature(s)
_as_feature(p::Pair{<:AbstractString,<:Integer}) = _make_feature(p.first, p.second)

_as_feature(x) = throw(ArgumentError(
    "cannot read $(repr(x)) as a shaping feature. Pass a feature string " *
    "(\"kern=0\", \"-liga\", \"aalt[3:5]=2\"), a \"tag\" => value pair, " *
    "or a Feature."))

"""
    shape!(font::Font, buf::Buffer; features = nothing, shapers = nothing)

Shape the text in `buf` using `font`. Returns a `ShapeResult` with
glyph infos and positions.

`features` accepts HarfBuzz feature strings, `"tag" => value` pairs, or
[`Feature`](@ref) values. `shapers` restricts which backends may be tried, in
order; see [`shapers`](@ref) for the available names. Shaping raises an
error when no listed shaper can handle the buffer.
"""
function shape!(font::Font, buf::Buffer;
                features = nothing, shapers = nothing)::ShapeResult
    feat_arr = features === nothing ? Feature[] :
               Feature[_as_feature(f) for f in features]
    nfeat = length(feat_arr)

    GC.@preserve feat_arr begin
        fptr = nfeat == 0 ? C_NULL : pointer(feat_arr)
        if shapers === nothing
            ccall((:hb_shape, libhb), Cvoid,
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cuint),
                  font.ptr, buf.ptr, fptr, Cuint(nfeat))
        else
            names = String[String(s) for s in shapers]
            refs = [Base.cconvert(Cstring, s) for s in names]
            GC.@preserve refs begin
                list = Cstring[Base.unsafe_convert(Cstring, r) for r in refs]
                push!(list, Cstring(C_NULL))
                ok = GC.@preserve list ccall(
                    (:hb_shape_full, libhb), Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cuint, Ptr{Cstring}),
                    font.ptr, buf.ptr, fptr, Cuint(nfeat), pointer(list))
                ok == 0 && throw(ErrorException(
                    "shaping failed; no usable shaper among " *
                    join(names, ", ")))
            end
        end
    end

    infos = glyph_infos(buf)
    positions = glyph_positions(buf)
    @assert length(infos) == length(positions) "glyph info/position count mismatch"
    return ShapeResult(infos, positions)
end

"""
    shape(font::Font, text::AbstractString;
          features = nothing, shapers = nothing) -> ShapeResult

One-shot convenience: create a buffer, add text, guess segment
properties, shape, and return the result.

```julia
result = shape(font, "Hello")
result = shape(font, "AVATAR"; features = ["kern=0"])
result = shape(font, "AVATAR"; features = ["kern" => 0])
```
"""
function shape(font::Font, text::AbstractString;
               features = nothing, shapers = nothing)::ShapeResult
    buf = Buffer()
    add_text!(buf, text)
    guess_segment_properties!(buf)
    return shape!(font, buf; features = features, shapers = shapers)
end

# --- Serialization --------------------------------------------------------

const _SERIALIZE_FORMATS = Dict(:text => tag("TEXT"), :json => tag("JSON"))

const _SERIALIZE_FLAGS = (
    :no_clusters => UInt32(0x0001),
    :no_positions => UInt32(0x0002),
    :no_glyph_names => UInt32(0x0004),
    :glyph_extents => UInt32(0x0008),
    :glyph_flags => UInt32(0x0010),
    :no_advances => UInt32(0x0020),
)

"""
    serialize(buf::Buffer; font = nothing, format = :text, flags = Symbol[]) -> String

Render the buffer's glyphs as text, in the same formats the `hb-shape`
command-line tool produces. `:text` is the compact form
(`glyph=cluster+advance`), `:json` an array of objects.

`font` is what turns glyph IDs into names; without it, glyphs are
serialized by number. Flags: $(join(map(p -> ":" * String(p.first), _SERIALIZE_FLAGS), ", ")).

This is the basis for golden tests: shape, serialize, compare to a stored
string.
"""
function serialize(buf::Buffer; font::Union{Nothing,Font} = nothing,
                   format::Symbol = :text, flags = Symbol[],
                   start::Integer = 0, stop::Integer = length(buf))::String
    fmt = get(_SERIALIZE_FORMATS, format, nothing)
    fmt === nothing && throw(ArgumentError(
        "unknown serialization format :$format (expected :text or :json)"))
    fl = _flags_value(flags, _SERIALIZE_FLAGS, "serialization flag")
    fontptr = font === nothing ? C_NULL : font.ptr

    n = Int(stop) - Int(start)
    n <= 0 && return ""

    cap = max(256, 64 * n)
    while true
        out = Vector{UInt8}(undef, cap)
        consumed = Ref{Cuint}(0)
        got = ccall((:hb_buffer_serialize_glyphs, libhb), Cuint,
                    (Ptr{Cvoid}, Cuint, Cuint, Ptr{UInt8}, Cuint, Ref{Cuint},
                     Ptr{Cvoid}, UInt32, Cuint),
                    buf.ptr, Cuint(start), Cuint(stop), out, Cuint(cap),
                    consumed, fontptr, fmt, Cuint(fl))
        Int(got) == n && return String(out[1:Int(consumed[])])
        cap *= 2
        cap > 1 << 26 && throw(ErrorException("buffer serialization did not fit"))
    end
end

"""
    deserialize!(buf::Buffer, text::AbstractString;
                 font = nothing, format = :text) -> Buffer

Parse a serialized glyph list back into `buf`, the inverse of
[`serialize`](@ref).
"""
function deserialize!(buf::Buffer, text::AbstractString;
                      font::Union{Nothing,Font} = nothing,
                      format::Symbol = :text)
    fmt = get(_SERIALIZE_FORMATS, format, nothing)
    fmt === nothing && throw(ArgumentError(
        "unknown serialization format :$format (expected :text or :json)"))
    fontptr = font === nothing ? C_NULL : font.ptr

    # HarfBuzz 8.x rejects the bracketed text form that its OWN
    # `serialize` emits -- `[H=0+694|e=1+694]` -- which 10.x accepts, so
    # `deserialize!(serialize(buf))` failed outright on the older
    # series. 8.x parses the bare form, and commits a glyph only once a
    # `|` closes it, so the last one is dropped unless the string ends
    # in one.
    #
    # Rewritten BEFORE the call and not as a retry after a failure:
    # `hb_buffer_deserialize_glyphs` APPENDS, and a rejected parse still
    # leaves behind whatever it managed to read. Retrying on top of that
    # buffer duplicated the glyphs.
    s = String(text)
    if format === :text && !_accepts_bracketed_text() &&
            startswith(s, '[') && endswith(s, ']')
        inner = s[nextind(s, 1):prevind(s, lastindex(s))]
        s = isempty(inner) || endswith(inner, '|') ? inner : inner * "|"
    end

    ok = ccall((:hb_buffer_deserialize_glyphs, libhb), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Cint, Ref{Ptr{UInt8}}, Ptr{Cvoid}, UInt32),
               buf.ptr, s, Cint(sizeof(s)), Ref{Ptr{UInt8}}(C_NULL), fontptr, fmt)
    ok == 0 && throw(ArgumentError("cannot parse serialized glyphs"))
    return buf
end

# True when this `libharfbuzz` parses the bracketed text form that
# `serialize` produces. HarfBuzz 10 does; 8.x does not.
#
# A capability probe rather than a version comparison, and cheap: one
# parse of `[1=0+100]` into a throwaway buffer, cached forever.
const _ACCEPTS_BRACKETED_TEXT = Ref{Union{Nothing,Bool}}(nothing)

function _accepts_bracketed_text()::Bool
    v = _ACCEPTS_BRACKETED_TEXT[]
    v === nothing || return v
    ok = try
        probe = Buffer()
        s = "[1=0+100]"
        ccall((:hb_buffer_deserialize_glyphs, libhb), Cint,
              (Ptr{Cvoid}, Ptr{UInt8}, Cint, Ref{Ptr{UInt8}}, Ptr{Cvoid}, UInt32),
              probe.ptr, s, Cint(sizeof(s)), Ref{Ptr{UInt8}}(C_NULL),
              C_NULL, _SERIALIZE_FORMATS[:text]) != 0
    catch
        true  # Probe failed for some other reason; leave parsing alone.
    end
    _ACCEPTS_BRACKETED_TEXT[] = ok
    return ok
end

const _DIFF_FLAGS = (
    :content_type_mismatch => UInt32(0x0001),
    :length_mismatch => UInt32(0x0002),
    :notdef_present => UInt32(0x0004),
    :dotted_circle_present => UInt32(0x0008),
    :codepoint_mismatch => UInt32(0x0010),
    :cluster_mismatch => UInt32(0x0020),
    :glyph_flags_mismatch => UInt32(0x0040),
    :position_mismatch => UInt32(0x0080),
)

"""
    diff(reference::Buffer, other::Buffer;
         dotted_circle_glyph = -1, position_fuzz = 0) -> Vector{Symbol}

Compare two buffers. An empty result means they are equal; otherwise the
symbols say how they differ, e.g. `:length_mismatch`,
`:codepoint_mismatch`, `:position_mismatch`.
"""
function diff(reference::Buffer, other::Buffer;
              dotted_circle_glyph::Integer = -1,
              position_fuzz::Integer = 0)::Vector{Symbol}
    v = ccall((:hb_buffer_diff, libhb), Cuint,
              (Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Cuint),
              reference.ptr, other.ptr,
              reinterpret(UInt32, Int32(dotted_circle_glyph)),
              Cuint(position_fuzz))
    return _flags_symbols(v, _DIFF_FLAGS)
end

# --- Shaping trace --------------------------------------------------------

# Trampoline for hb_buffer_message_func_t. The Buffer itself is passed as
# user_data so the Julia callback can be recovered.
function _message_trampoline(bufptr::Ptr{Cvoid}, fontptr::Ptr{Cvoid},
                            msg::Ptr{UInt8}, user::Ptr{Cvoid})::Cint
    try
        buf = unsafe_pointer_to_objref(user)::Buffer
        f = buf._message
        f === nothing && return Cint(1)
        return f(unsafe_string(msg)) === false ? Cint(0) : Cint(1)
    catch
        # Never let a Julia exception unwind through C.
        return Cint(1)
    end
end

const _MESSAGE_CFUNC = Ref{Ptr{Cvoid}}(C_NULL)

"""
    message_func!(buf::Buffer, f)

Call `f(message::String)` at each stage of shaping this buffer -- the same
trace `hb-shape --trace` prints. Return `false` from `f` to skip the stage
being announced. Pass `nothing` to remove the callback.

The buffer must stay alive for as long as the callback is installed.
"""
function message_func!(buf::Buffer, f)
    buf._message = f
    if f === nothing
        ccall((:hb_buffer_set_message_func, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
              buf.ptr, C_NULL, C_NULL, C_NULL)
    else
        ccall((:hb_buffer_set_message_func, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
              buf.ptr, _MESSAGE_CFUNC[], pointer_from_objref(buf), C_NULL)
    end
    return buf
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

# --- Glyph metrics --------------------------------------------------------

"""
    GlyphExtents

Bounding box of a glyph, in the font's scale units. `y` grows upward, so a
cap-height glyph has a positive `y_bearing` and a negative `height`.

- `x_bearing`, `y_bearing` — top-left corner relative to the origin.
- `width`, `height` — extent from that corner.
"""
struct GlyphExtents
    x_bearing::Int32
    y_bearing::Int32
    width::Int32
    height::Int32
end

"""
    FontExtents

Line metrics, in the font's scale units.

- `ascender` — distance above the baseline, positive.
- `descender` — distance below it, negative.
- `line_gap` — extra leading between lines.
"""
struct FontExtents
    ascender::Int32
    descender::Int32
    line_gap::Int32
end

# hb_font_extents_t has nine reserved fields after the three public ones.
struct _HbFontExtentsRaw
    ascender::Int32
    descender::Int32
    line_gap::Int32
    reserved::NTuple{9,Int32}
end

"""
    glyph_h_advance(font::Font, glyph) -> Int32
    glyph_v_advance(font::Font, glyph) -> Int32

Advance for one glyph, in the font's scale units. This is the metric
shaping reports; use it when measuring text you have not shaped.
"""
glyph_h_advance(f::Font, glyph::Integer)::Int32 =
    ccall((:hb_font_get_glyph_h_advance, libhb), Int32,
          (Ptr{Cvoid}, UInt32), f.ptr, UInt32(glyph))

glyph_v_advance(f::Font, glyph::Integer)::Int32 =
    ccall((:hb_font_get_glyph_v_advance, libhb), Int32,
          (Ptr{Cvoid}, UInt32), f.ptr, UInt32(glyph))

"""
    glyph_h_advances(font::Font, glyphs) -> Vector{Int32}

Advances for many glyphs in one call, which lets HarfBuzz avoid repeating
per-glyph setup.
"""
function glyph_h_advances(f::Font, glyphs::AbstractVector{<:Integer})::Vector{Int32}
    gids = UInt32[UInt32(g) for g in glyphs]
    out = Vector{Int32}(undef, length(gids))
    isempty(gids) && return out
    GC.@preserve gids out begin
        ccall((:hb_font_get_glyph_h_advances, libhb), Cvoid,
              (Ptr{Cvoid}, Cuint, Ptr{UInt32}, Cuint, Ptr{Int32}, Cuint),
              f.ptr, Cuint(length(gids)), pointer(gids), Cuint(sizeof(UInt32)),
              pointer(out), Cuint(sizeof(Int32)))
    end
    return out
end

"""
    glyph_extents(font::Font, glyph) -> Union{GlyphExtents,Nothing}

Bounding box of a glyph, or `nothing` when the font cannot report one.
"""
function glyph_extents(f::Font, glyph::Integer)::Union{GlyphExtents,Nothing}
    out = Ref{GlyphExtents}()
    ok = ccall((:hb_font_get_glyph_extents, libhb), Cint,
               (Ptr{Cvoid}, UInt32, Ref{GlyphExtents}), f.ptr, UInt32(glyph), out)
    return ok != 0 ? out[] : nothing
end

"""
    font_extents(font::Font; direction = :ltr) -> FontExtents

Line metrics for the given direction. Vertical metrics are synthesised
when the font carries none.
"""
function font_extents(f::Font; direction::Symbol = :ltr)::FontExtents
    out = Ref{_HbFontExtentsRaw}()
    sym = direction in (:ttb, :btt) ? :hb_font_get_v_extents : :hb_font_get_h_extents
    if sym === :hb_font_get_v_extents
        ccall((:hb_font_get_v_extents, libhb), Cint,
              (Ptr{Cvoid}, Ref{_HbFontExtentsRaw}), f.ptr, out)
    else
        ccall((:hb_font_get_h_extents, libhb), Cint,
              (Ptr{Cvoid}, Ref{_HbFontExtentsRaw}), f.ptr, out)
    end
    r = out[]
    return FontExtents(r.ascender, r.descender, r.line_gap)
end

"""
    glyph_h_origin(font::Font, glyph) -> Union{Tuple{Int,Int},Nothing}
    glyph_v_origin(font::Font, glyph) -> Union{Tuple{Int,Int},Nothing}

Origin a glyph is drawn from, for horizontal or vertical layout.
"""
function glyph_h_origin(f::Font, glyph::Integer)
    x = Ref{Int32}(0); y = Ref{Int32}(0)
    ok = ccall((:hb_font_get_glyph_h_origin, libhb), Cint,
               (Ptr{Cvoid}, UInt32, Ref{Int32}, Ref{Int32}),
               f.ptr, UInt32(glyph), x, y)
    return ok != 0 ? (Int(x[]), Int(y[])) : nothing
end

function glyph_v_origin(f::Font, glyph::Integer)
    x = Ref{Int32}(0); y = Ref{Int32}(0)
    ok = ccall((:hb_font_get_glyph_v_origin, libhb), Cint,
               (Ptr{Cvoid}, UInt32, Ref{Int32}, Ref{Int32}),
               f.ptr, UInt32(glyph), x, y)
    return ok != 0 ? (Int(x[]), Int(y[])) : nothing
end

"""
    glyph_h_kerning(font::Font, left, right) -> Int32

Kerning from the legacy `kern` table only. Fonts that kern through GPOS —
most of them — return 0 here; their kerning arrives through shaping.
"""
glyph_h_kerning(f::Font, left::Integer, right::Integer)::Int32 =
    ccall((:hb_font_get_glyph_h_kerning, libhb), Int32,
          (Ptr{Cvoid}, UInt32, UInt32), f.ptr, UInt32(left), UInt32(right))

# --- Glyph names ----------------------------------------------------------

"""
    glyph_name(font::Font, glyph) -> Union{String,Nothing}

The glyph's name from the `post` table, or `nothing` when the font has
none.
"""
function glyph_name(f::Font, glyph::Integer)::Union{String,Nothing}
    buf = Vector{UInt8}(undef, 128)
    ok = ccall((:hb_font_get_glyph_name, libhb), Cint,
               (Ptr{Cvoid}, UInt32, Ptr{UInt8}, Cuint),
               f.ptr, UInt32(glyph), buf, Cuint(length(buf)))
    ok == 0 && return nothing
    stop = findfirst(==(0x00), buf)
    return String(buf[1:(stop === nothing ? length(buf) : stop - 1)])
end

"""
    glyph_from_name(font::Font, name) -> Union{UInt32,Nothing}

The glyph with this name, or `nothing`.
"""
function glyph_from_name(f::Font, name::AbstractString)::Union{UInt32,Nothing}
    out = Ref{UInt32}(0)
    ok = ccall((:hb_font_get_glyph_from_name, libhb), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Cint, Ref{UInt32}),
               f.ptr, String(name), Cint(sizeof(name)), out)
    return ok != 0 ? out[] : nothing
end

# --- Sets -----------------------------------------------------------------

# `hb_set_t` is not exposed: HarfBuzz uses it as an out-parameter, and a
# Julia `Set` is friendlier than a wrapper nobody would keep around.
function _collect_set(fill!::Function)::Set{UInt32}
    set = ccall((:hb_set_create, libhb), Ptr{Cvoid}, ())
    set == C_NULL && throw(ErrorException("hb_set_create failed"))
    try
        fill!(set)
        out = Set{UInt32}()
        cp = Ref{UInt32}(typemax(UInt32))   # HB_SET_VALUE_INVALID
        while ccall((:hb_set_next, libhb), Cint,
                    (Ptr{Cvoid}, Ref{UInt32}), set, cp) != 0
            push!(out, cp[])
        end
        return out
    finally
        ccall((:hb_set_destroy, libhb), Cvoid, (Ptr{Cvoid},), set)
    end
end

"""
    unicodes(face::Face) -> Set{UInt32}

Every Unicode codepoint the face's `cmap` covers.
"""
unicodes(f::Face)::Set{UInt32} = _collect_set() do set
    ccall((:hb_face_collect_unicodes, libhb), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}), f.ptr, set)
end

# --- Name table -----------------------------------------------------------

const _NAME_IDS = (
    :copyright => 0, :family => 1, :subfamily => 2, :unique_id => 3,
    :full_name => 4, :version => 5, :postscript_name => 6, :trademark => 7,
    :manufacturer => 8, :designer => 9, :description => 10,
    :vendor_url => 11, :designer_url => 12, :license => 13,
    :license_url => 14, :typographic_family => 16,
    :typographic_subfamily => 17, :mac_full_name => 18, :sample_text => 19,
    :cid_findfont_name => 20, :wws_family => 21, :wws_subfamily => 22,
    :light_background => 23, :dark_background => 24,
    :variations_ps_prefix => 25,
)

_name_id(id::Integer) = UInt32(id)
function _name_id(id::Symbol)
    i = findfirst(p -> p.first === id, _NAME_IDS)
    i === nothing && throw(ArgumentError(
        "unknown name id :$id (expected one of " *
        join(map(p -> ":" * String(p.first), _NAME_IDS), ", ") * ")"))
    return UInt32(_NAME_IDS[i].second)
end

"""
    name(face::Face, id; language = "en") -> Union{String,Nothing}

A record from the font's `name` table. `id` is a `Symbol` such as
`:family`, `:subfamily`, `:license` or `:version`, or a raw numeric name
ID. Returns `nothing` when the font carries no such record.
"""
function name(f::Face, id; language::AbstractString = "en")::Union{String,Nothing}
    nid = _name_id(id)
    lang = _language_value(language)
    size = Ref{Cuint}(0)
    len = ccall((:hb_ot_name_get_utf8, libhb), Cuint,
                (Ptr{Cvoid}, UInt32, Ptr{Cvoid}, Ref{Cuint}, Ptr{UInt8}),
                f.ptr, nid, lang, size, C_NULL)
    len == 0 && return nothing
    buf = Vector{UInt8}(undef, Int(len) + 1)
    size[] = Cuint(length(buf))
    ccall((:hb_ot_name_get_utf8, libhb), Cuint,
          (Ptr{Cvoid}, UInt32, Ptr{Cvoid}, Ref{Cuint}, Ptr{UInt8}),
          f.ptr, nid, lang, size, buf)
    return String(buf[1:Int(len)])
end

struct _HbOtNameEntryRaw
    name_id::UInt32
    var::UInt32
    language::Ptr{Cvoid}
end

"""
    name_entries(face::Face) -> Vector{NamedTuple}

Every record the `name` table holds, as `(name_id, language)` pairs. Use
[`name`](@ref) to read one.
"""
function name_entries(f::Face)
    n = Ref{Cuint}(0)
    ptr = ccall((:hb_ot_name_list_names, libhb), Ptr{_HbOtNameEntryRaw},
                (Ptr{Cvoid}, Ref{Cuint}), f.ptr, n)
    ptr == C_NULL && return NamedTuple[]
    raw = unsafe_wrap(Array, ptr, Int(n[]))
    return [(name_id = Int(r.name_id), language = _language_symbol(r.language))
            for r in raw]
end

# --- OpenType metrics and style ------------------------------------------

const _METRIC_TAGS = (
    :horizontal_ascender => "hasc", :horizontal_descender => "hdsc",
    :horizontal_line_gap => "hlgp", :horizontal_clipping_ascent => "hcla",
    :horizontal_clipping_descent => "hcld", :vertical_ascender => "vasc",
    :vertical_descender => "vdsc", :vertical_line_gap => "vlgp",
    :horizontal_caret_rise => "hcrs", :horizontal_caret_run => "hcrn",
    :horizontal_caret_offset => "hcof", :vertical_caret_rise => "vcrs",
    :vertical_caret_run => "vcrn", :vertical_caret_offset => "vcof",
    :x_height => "xhgt", :cap_height => "cpht",
    :subscript_em_x_size => "sbxs", :subscript_em_y_size => "sbys",
    :subscript_em_x_offset => "sbxo", :subscript_em_y_offset => "sbyo",
    :superscript_em_x_size => "spxs", :superscript_em_y_size => "spys",
    :superscript_em_x_offset => "spxo", :superscript_em_y_offset => "spyo",
    :strikeout_size => "strs", :strikeout_offset => "stro",
    :underline_size => "unds", :underline_offset => "undo",
)

"""
    metric(font::Font, name::Symbol; fallback = true) -> Union{Int32,Nothing}

An OpenType metric such as `:x_height`, `:cap_height`, `:underline_offset`
or `:strikeout_size`, in the font's scale units.

With `fallback = true` HarfBuzz synthesises a value when the font carries
none; with `fallback = false` a missing metric returns `nothing`.

Available: $(join(map(p -> ":" * String(p.first), _METRIC_TAGS), ", ")).
"""
function metric(f::Font, name::Symbol; fallback::Bool = true)
    i = findfirst(p -> p.first === name, _METRIC_TAGS)
    i === nothing && throw(ArgumentError(
        "unknown metric :$name (expected one of " *
        join(map(p -> ":" * String(p.first), _METRIC_TAGS), ", ") * ")"))
    t = tag(_METRIC_TAGS[i].second)
    out = Ref{Int32}(0)
    if fallback
        ccall((:hb_ot_metrics_get_position_with_fallback, libhb), Cvoid,
              (Ptr{Cvoid}, UInt32, Ref{Int32}), f.ptr, t, out)
        return out[]
    end
    ok = ccall((:hb_ot_metrics_get_position, libhb), Cint,
               (Ptr{Cvoid}, UInt32, Ref{Int32}), f.ptr, t, out)
    return ok != 0 ? out[] : nothing
end

const _STYLE_TAGS = (
    :italic => "ital", :optical_size => "opsz", :slant_angle => "slnt",
    :slant_ratio => "Slnt", :width => "wdth", :weight => "wght",
)

"""
    style(font::Font, name::Symbol) -> Float64

A style value: `:weight` (100–900), `:width` (a percentage),
`:italic` (0 or 1), `:slant_angle` in degrees, `:slant_ratio`, or
`:optical_size` in points. Reflects any variation set on the font.
"""
function style(f::Font, name::Symbol)::Float64
    i = findfirst(p -> p.first === name, _STYLE_TAGS)
    i === nothing && throw(ArgumentError(
        "unknown style :$name (expected one of " *
        join(map(p -> ":" * String(p.first), _STYLE_TAGS), ", ") * ")"))
    return Float64(ccall((:hb_style_get_value, libhb), Cfloat,
                         (Ptr{Cvoid}, UInt32), f.ptr, tag(_STYLE_TAGS[i].second)))
end

# --- Variable fonts -------------------------------------------------------

struct _HbOtVarAxisInfoRaw
    axis_index::UInt32
    tag::UInt32
    name_id::UInt32
    flags::UInt32
    min_value::Cfloat
    default_value::Cfloat
    max_value::Cfloat
    reserved::UInt32
end

struct _HbVariationRaw
    tag::UInt32
    value::Cfloat
end

"""
    has_variations(face::Face) -> Bool

True when the face carries an `fvar` table, i.e. it is a variable font.
"""
has_variations(f::Face)::Bool =
    ccall((:hb_ot_var_has_data, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

"""
    axes(face::Face) -> Vector{NamedTuple}

The variation axes, each as
`(index, tag, min_value, default_value, max_value)`. Empty for a static
font.
"""
function axes(f::Face)
    count = Int(ccall((:hb_ot_var_get_axis_count, libhb), Cuint,
                      (Ptr{Cvoid},), f.ptr))
    count == 0 && return NamedTuple[]
    n = Ref{Cuint}(count)
    buf = Vector{_HbOtVarAxisInfoRaw}(undef, count)
    n[] = Cuint(count)
    GC.@preserve buf begin
        ccall((:hb_ot_var_get_axis_infos, libhb), Cuint,
              (Ptr{Cvoid}, Cuint, Ref{Cuint}, Ptr{Cvoid}),
              f.ptr, Cuint(0), n, pointer(buf))
    end
    return [(index = Int(a.axis_index), tag = tag_string(a.tag),
             min_value = Float64(a.min_value),
             default_value = Float64(a.default_value),
             max_value = Float64(a.max_value)) for a in buf[1:Int(n[])]]
end

"""
    named_instances(face::Face) -> Vector{NamedTuple}

The named instances a variable font ships, each as `(index, name, coords)`
where `coords` are design-space values, one per axis.
"""
function named_instances(f::Face)
    count = Int(ccall((:hb_ot_var_get_named_instance_count, libhb), Cuint,
                      (Ptr{Cvoid},), f.ptr))
    count == 0 && return NamedTuple[]
    naxes = length(axes(f))
    out = NamedTuple[]
    for i in 0:(count - 1)
        nid = ccall((:hb_ot_var_named_instance_get_subfamily_name_id, libhb),
                    UInt32, (Ptr{Cvoid}, Cuint), f.ptr, Cuint(i))
        n = Ref{Cuint}(naxes)
        coords = Vector{Cfloat}(undef, naxes)
        GC.@preserve coords begin
            ccall((:hb_ot_var_named_instance_get_design_coords, libhb), Cuint,
                  (Ptr{Cvoid}, Cuint, Ref{Cuint}, Ptr{Cfloat}),
                  f.ptr, Cuint(i), n, pointer(coords))
        end
        label = name(f, nid)
        push!(out, (index = i, name = label === nothing ? "" : label,
                    coords = Float64.(coords[1:Int(n[])])))
    end
    return out
end

"""
    set_variations!(font::Font, variations)

Position the font in its design space. `variations` is any collection of
`"tag" => value` pairs, in design-space units.

```julia
set_variations!(font, ["wght" => 700, "wdth" => 87.5])
```
"""
function set_variations!(f::Font, variations)
    vars = _HbVariationRaw[
        _HbVariationRaw(tag(String(p.first)), Cfloat(p.second)) for p in variations]
    GC.@preserve vars begin
        ccall((:hb_font_set_variations, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{Cvoid}, Cuint),
              f.ptr, isempty(vars) ? C_NULL : pointer(vars), Cuint(length(vars)))
    end
    return f
end

"""
    var_coords_design(font::Font) -> Vector{Float64}
    var_coords_normalized(font::Font) -> Vector{Float64}

The font's position in design space (the units axes are declared in) or in
normalised space (−1 … 0 … 1 per axis).
"""
function var_coords_design(f::Font)::Vector{Float64}
    n = Ref{Cuint}(0)
    ptr = ccall((:hb_font_get_var_coords_design, libhb), Ptr{Cfloat},
                (Ptr{Cvoid}, Ref{Cuint}), f.ptr, n)
    ptr == C_NULL && return Float64[]
    return Float64.(unsafe_wrap(Array, ptr, Int(n[])))
end

function var_coords_normalized(f::Font)::Vector{Float64}
    n = Ref{Cuint}(0)
    ptr = ccall((:hb_font_get_var_coords_normalized, libhb), Ptr{Cint},
                (Ptr{Cvoid}, Ref{Cuint}), f.ptr, n)
    ptr == C_NULL && return Float64[]
    # Normalised coordinates are 2.14 fixed point.
    return [Float64(v) / 16384 for v in unsafe_wrap(Array, ptr, Int(n[]))]
end

# --- OpenType layout ------------------------------------------------------

"""
    has_substitution(face::Face) -> Bool
    has_positioning(face::Face) -> Bool
    has_glyph_classes(face::Face) -> Bool

Whether the face carries a GSUB table, a GPOS table, or GDEF glyph
classes.
"""
has_substitution(f::Face)::Bool =
    ccall((:hb_ot_layout_has_substitution, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

has_positioning(f::Face)::Bool =
    ccall((:hb_ot_layout_has_positioning, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

has_glyph_classes(f::Face)::Bool =
    ccall((:hb_ot_layout_has_glyph_classes, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

function _layout_table(t::Symbol)::UInt32
    t in (:GSUB, :GPOS) || throw(ArgumentError(
        "unknown layout table :$t (expected :GSUB or :GPOS)"))
    return tag(String(t))
end

# Both tag-listing calls share this in/out-count loop.
function _collect_tags(call::Function)::Vector{String}
    tags = String[]
    offset = Cuint(0)
    buf = Vector{UInt32}(undef, 32)
    while true
        count = Ref{Cuint}(length(buf))
        total = call(offset, count, buf)
        n = Int(count[])
        n == 0 && break
        append!(tags, tag_string(buf[i]) for i in 1:n)
        offset += Cuint(n)
        offset >= total && break
    end
    return tags
end

"""
    layout_script_tags(face::Face, table::Symbol) -> Vector{String}

The script tags a layout table covers, e.g. `"latn"`, `"DFLT"`. `table`
is `:GSUB` or `:GPOS`.
"""
layout_script_tags(f::Face, table::Symbol)::Vector{String} =
    (t = _layout_table(table); _collect_tags() do offset, count, buf
        ccall((:hb_ot_layout_table_get_script_tags, libhb), Cuint,
              (Ptr{Cvoid}, UInt32, Cuint, Ref{Cuint}, Ptr{UInt32}),
              f.ptr, t, offset, count, buf)
    end)

"""
    layout_feature_tags(face::Face, table::Symbol) -> Vector{String}

Every feature tag a layout table defines, e.g. `"liga"`, `"kern"`.
"""
layout_feature_tags(f::Face, table::Symbol)::Vector{String} =
    (t = _layout_table(table); _collect_tags() do offset, count, buf
        ccall((:hb_ot_layout_table_get_feature_tags, libhb), Cuint,
              (Ptr{Cvoid}, UInt32, Cuint, Ref{Cuint}, Ptr{UInt32}),
              f.ptr, t, offset, count, buf)
    end)

const _GLYPH_CLASSES = (:unclassified, :base_glyph, :ligature, :mark, :component)

"""
    glyph_class(face::Face, glyph) -> Symbol

The glyph's GDEF class: `:base_glyph`, `:ligature`, `:mark`, `:component`,
or `:unclassified`.
"""
function glyph_class(f::Face, glyph::Integer)::Symbol
    v = ccall((:hb_ot_layout_get_glyph_class, libhb), Cint,
              (Ptr{Cvoid}, UInt32), f.ptr, UInt32(glyph))
    return 0 <= v <= 4 ? _GLYPH_CLASSES[v + 1] : :unclassified
end

const _BASELINE_TAGS = (:romn, :hang, :icfb, :icft, :ideo, :idtp, :math)

"""
    baseline(font::Font, which::Symbol; direction = :ltr,
             script = :Latn, language = "en") -> Int32

Position of a baseline, in the font's scale units. `which` is `:romn`
(roman, the Latin baseline), `:hang` (hanging), `:ideo`/`:idtp`
(ideographic), `:icfb`/`:icft` (ideographic character face) or `:math`.

A value is always produced: HarfBuzz falls back to a sensible synthesis
when the font declares no `BASE` table.
"""
function baseline(f::Font, which::Symbol; direction::Symbol = :ltr,
                  script::Symbol = :Latn, language::AbstractString = "en")::Int32
    which in _BASELINE_TAGS && (nothing)
    which in _BASELINE_TAGS || throw(ArgumentError(
        "unknown baseline :$which (expected one of " *
        join(map(b -> ":" * String(b), _BASELINE_TAGS), ", ") * ")"))
    out = Ref{Int32}(0)
    ccall((:hb_ot_layout_get_baseline_with_fallback, libhb), Cvoid,
          (Ptr{Cvoid}, UInt32, Cint, UInt32, UInt32, Ref{Int32}),
          f.ptr, tag(String(which)), _direction_value(direction),
          _script_value(script), tag(String(language)), out)
    return out[]
end

# --- Font state -----------------------------------------------------------

"""
    sub_font(font::Font) -> Font

A child font sharing the parent's face and starting from its settings.
Changing the child leaves the parent untouched, which is how a renderer
varies size or variations without re-reading the face.
"""
function sub_font(f::Font)::Font
    ptr = ccall((:hb_font_create_sub_font, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), f.ptr)
    ptr == C_NULL && throw(ErrorException("hb_font_create_sub_font failed"))
    # `hb_font_create_sub_font` takes its own reference on the parent, but
    # the parent's backing objects must outlive the child too.
    child = Font(ptr, f._face, f)
    finalizer(_font_destroy, child)
    return child
end

"""
    synthetic_slant(font::Font) -> Float64
    synthetic_slant!(font::Font, ratio)

Skew applied to glyphs to fake an italic, as a ratio (0.25 is a common
choice). Purely graphical: no different glyphs are selected.
"""
synthetic_slant(f::Font)::Float64 =
    Float64(ccall((:hb_font_get_synthetic_slant, libhb), Cfloat, (Ptr{Cvoid},), f.ptr))

function synthetic_slant!(f::Font, ratio::Real)
    ccall((:hb_font_set_synthetic_slant, libhb), Cvoid,
          (Ptr{Cvoid}, Cfloat), f.ptr, Cfloat(ratio))
    return f
end

"""
    synthetic_bold(font::Font) -> Tuple{Float64,Float64,Bool}
    synthetic_bold!(font::Font, x_embolden, y_embolden = x_embolden;
                    in_place = false)

Emboldening applied to fake a bold weight, as a fraction of the em. Prefer
a real bold or a `wght` variation where the font offers one.
"""
function synthetic_bold(f::Font)
    x = Ref{Cfloat}(0); y = Ref{Cfloat}(0); inplace = Ref{Cint}(0)
    ccall((:hb_font_get_synthetic_bold, libhb), Cvoid,
          (Ptr{Cvoid}, Ref{Cfloat}, Ref{Cfloat}, Ref{Cint}), f.ptr, x, y, inplace)
    return (Float64(x[]), Float64(y[]), inplace[] != 0)
end

function synthetic_bold!(f::Font, x_embolden::Real, y_embolden::Real = x_embolden;
                         in_place::Bool = false)
    ccall((:hb_font_set_synthetic_bold, libhb), Cvoid,
          (Ptr{Cvoid}, Cfloat, Cfloat, Cint),
          f.ptr, Cfloat(x_embolden), Cfloat(y_embolden), Cint(in_place))
    return f
end

# True when `libharfbuzz` exports `hb_font_is_synthetic`, added in
# HarfBuzz 10.
#
# The ONE symbol in this package that the 8.x series does not have, and
# the only reason `[compat] HarfBuzz_jll` needs to know which series it
# got. Probed rather than inferred from a version number, and resolved
# once -- it cannot change while the library is loaded.
const _HAS_IS_SYNTHETIC = Ref{Union{Nothing,Bool}}(nothing)

function _has_is_synthetic()::Bool
    v = _HAS_IS_SYNTHETIC[]
    v === nothing || return v
    ok = try
        h = Libdl.dlopen(libhb, Libdl.RTLD_LAZY)
        Libdl.dlsym(h, :hb_font_is_synthetic; throw_error = false) !== nothing
    catch
        false
    end
    _HAS_IS_SYNTHETIC[] = ok
    return ok
end

"""
    is_synthetic(font::Font) -> Bool

True when synthetic bold or slant is in effect.

On HarfBuzz 8.x, where `hb_font_is_synthetic` does not exist, this is
computed from the two settings it reports on. That is not an
approximation: upstream's implementation is exactly
`x_embolden || y_embolden || slant`, and both getters are present in
8.x, so the two paths agree by construction.
"""
function is_synthetic(f::Font)::Bool
    if _has_is_synthetic()
        return ccall((:hb_font_is_synthetic, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0
    end
    x, y, _ = synthetic_bold(f)
    return x != 0 || y != 0 || synthetic_slant(f) != 0
end

"""
    make_immutable!(font::Font)
    is_immutable(font::Font) -> Bool

Freeze a font so later changes are refused. HarfBuzz objects are not
thread-safe while mutable; making one immutable is what allows sharing it
between threads.
"""
function make_immutable!(f::Font)
    ccall((:hb_font_make_immutable, libhb), Cvoid, (Ptr{Cvoid},), f.ptr)
    return f
end

is_immutable(f::Font)::Bool =
    ccall((:hb_font_is_immutable, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

# --- Unicode data ---------------------------------------------------------

# HarfBuzz's own Unicode tables, which shaping uses. Exposed because a
# caller doing its own segmentation needs the same answers the shaper used.
_unicode_funcs() = ccall((:hb_unicode_funcs_get_default, libhb), Ptr{Cvoid}, ())

"""
    script_of(codepoint) -> Symbol

The codepoint's script, as an ISO 15924 tag such as `:Latn` or `:Arab`.
"""
script_of(cp::Integer)::Symbol = _script_symbol(
    ccall((:hb_unicode_script, libhb), UInt32,
          (Ptr{Cvoid}, UInt32), _unicode_funcs(), UInt32(cp)))

const _GENERAL_CATEGORIES = (
    :control, :format, :unassigned, :private_use, :surrogate,
    :lowercase_letter, :modifier_letter, :other_letter, :titlecase_letter,
    :uppercase_letter, :spacing_mark, :enclosing_mark, :non_spacing_mark,
    :decimal_number, :letter_number, :other_number, :connect_punctuation,
    :dash_punctuation, :close_punctuation, :final_punctuation,
    :initial_punctuation, :other_punctuation, :open_punctuation,
    :currency_symbol, :modifier_symbol, :math_symbol, :other_symbol,
    :line_separator, :paragraph_separator, :space_separator,
)

"""
    general_category(codepoint) -> Symbol

The codepoint's Unicode general category, e.g. `:uppercase_letter`,
`:decimal_number`, `:non_spacing_mark`.
"""
function general_category(cp::Integer)::Symbol
    v = ccall((:hb_unicode_general_category, libhb), Cint,
              (Ptr{Cvoid}, UInt32), _unicode_funcs(), UInt32(cp))
    return 0 <= v < length(_GENERAL_CATEGORIES) ?
           _GENERAL_CATEGORIES[v + 1] : :unassigned
end

"""
    combining_class(codepoint) -> Int

The canonical combining class. 0 for a base character, 230 for a mark
above, and so on.
"""
combining_class(cp::Integer)::Int = Int(
    ccall((:hb_unicode_combining_class, libhb), Cint,
          (Ptr{Cvoid}, UInt32), _unicode_funcs(), UInt32(cp)))

"""
    mirroring(codepoint) -> UInt32

The codepoint's mirror image in right-to-left text — `(` becomes `)`.
Returns the codepoint itself when it has no mirror.
"""
mirroring(cp::Integer)::UInt32 =
    ccall((:hb_unicode_mirroring, libhb), UInt32,
          (Ptr{Cvoid}, UInt32), _unicode_funcs(), UInt32(cp))

"""
    compose(a, b) -> Union{UInt32,Nothing}

Canonical composition: `compose('e', 0x0301)` is `'é'`. `nothing` when the
pair does not compose.
"""
function compose(a::Integer, b::Integer)::Union{UInt32,Nothing}
    out = Ref{UInt32}(0)
    ok = ccall((:hb_unicode_compose, libhb), Cint,
               (Ptr{Cvoid}, UInt32, UInt32, Ref{UInt32}),
               _unicode_funcs(), UInt32(a), UInt32(b), out)
    return ok != 0 ? out[] : nothing
end

"""
    decompose(codepoint) -> Union{Tuple{UInt32,UInt32},Nothing}

Canonical decomposition, the inverse of [`compose`](@ref). `nothing` when
the codepoint does not decompose.
"""
function decompose(cp::Integer)::Union{Tuple{UInt32,UInt32},Nothing}
    a = Ref{UInt32}(0); b = Ref{UInt32}(0)
    ok = ccall((:hb_unicode_decompose, libhb), Cint,
               (Ptr{Cvoid}, UInt32, Ref{UInt32}, Ref{UInt32}),
               _unicode_funcs(), UInt32(cp), a, b)
    return ok != 0 ? (a[], b[]) : nothing
end

# --- Outlines -------------------------------------------------------------

"""
    PathCommand

One step of a glyph outline: an `op` (`:move_to`, `:line_to`,
`:quadratic_to`, `:cubic_to` or `:close_path`) and its control points, in
the font's scale units.

`:quadratic_to` carries one control point then the endpoint; `:cubic_to`
two control points then the endpoint; `:close_path` none.
"""
struct PathCommand
    op::Symbol
    points::Vector{Tuple{Float64,Float64}}
end

# The draw callbacks push into this, reached through `draw_data`.
mutable struct _DrawSink
    sink::Any
end

for (name, op, npoints) in ((:_draw_move_to, :move_to, 1),
                            (:_draw_line_to, :line_to, 1))
    @eval function $name(::Ptr{Cvoid}, draw_data::Ptr{Cvoid}, ::Ptr{Cvoid},
                         x::Cfloat, y::Cfloat, ::Ptr{Cvoid})::Cvoid
        try
            s = unsafe_pointer_to_objref(draw_data)::_DrawSink
            s.sink($(QuoteNode(op)), [(Float64(x), Float64(y))])
        catch
        end
        return nothing
    end
end

function _draw_quadratic_to(::Ptr{Cvoid}, draw_data::Ptr{Cvoid}, ::Ptr{Cvoid},
                            cx::Cfloat, cy::Cfloat, x::Cfloat, y::Cfloat,
                            ::Ptr{Cvoid})::Cvoid
    try
        s = unsafe_pointer_to_objref(draw_data)::_DrawSink
        s.sink(:quadratic_to, [(Float64(cx), Float64(cy)), (Float64(x), Float64(y))])
    catch
    end
    return nothing
end

function _draw_cubic_to(::Ptr{Cvoid}, draw_data::Ptr{Cvoid}, ::Ptr{Cvoid},
                        c1x::Cfloat, c1y::Cfloat, c2x::Cfloat, c2y::Cfloat,
                        x::Cfloat, y::Cfloat, ::Ptr{Cvoid})::Cvoid
    try
        s = unsafe_pointer_to_objref(draw_data)::_DrawSink
        s.sink(:cubic_to, [(Float64(c1x), Float64(c1y)),
                           (Float64(c2x), Float64(c2y)),
                           (Float64(x), Float64(y))])
    catch
    end
    return nothing
end

function _draw_close_path(::Ptr{Cvoid}, draw_data::Ptr{Cvoid}, ::Ptr{Cvoid},
                          ::Ptr{Cvoid})::Cvoid
    try
        s = unsafe_pointer_to_objref(draw_data)::_DrawSink
        s.sink(:close_path, Tuple{Float64,Float64}[])
    catch
    end
    return nothing
end

const _DRAW_FUNCS = Ref{Ptr{Cvoid}}(C_NULL)

function _init_draw_funcs()
    dfuncs = ccall((:hb_draw_funcs_create, libhb), Ptr{Cvoid}, ())
    dfuncs == C_NULL && throw(ErrorException("hb_draw_funcs_create failed"))
    ccall((:hb_draw_funcs_set_move_to_func, libhb), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), dfuncs,
          @cfunction(_draw_move_to, Cvoid,
                     (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cfloat, Cfloat, Ptr{Cvoid})),
          C_NULL, C_NULL)
    ccall((:hb_draw_funcs_set_line_to_func, libhb), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), dfuncs,
          @cfunction(_draw_line_to, Cvoid,
                     (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cfloat, Cfloat, Ptr{Cvoid})),
          C_NULL, C_NULL)
    ccall((:hb_draw_funcs_set_quadratic_to_func, libhb), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), dfuncs,
          @cfunction(_draw_quadratic_to, Cvoid,
                     (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cfloat, Cfloat,
                      Cfloat, Cfloat, Ptr{Cvoid})),
          C_NULL, C_NULL)
    ccall((:hb_draw_funcs_set_cubic_to_func, libhb), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), dfuncs,
          @cfunction(_draw_cubic_to, Cvoid,
                     (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cfloat, Cfloat,
                      Cfloat, Cfloat, Cfloat, Cfloat, Ptr{Cvoid})),
          C_NULL, C_NULL)
    ccall((:hb_draw_funcs_set_close_path_func, libhb), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), dfuncs,
          @cfunction(_draw_close_path, Cvoid,
                     (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid})),
          C_NULL, C_NULL)
    ccall((:hb_draw_funcs_make_immutable, libhb), Cvoid, (Ptr{Cvoid},), dfuncs)
    _DRAW_FUNCS[] = dfuncs
    return nothing
end

"""
    draw_glyph(f, font::Font, glyph)

Walk a glyph's outline, calling `f(op, points)` for each step. `op` is
`:move_to`, `:line_to`, `:quadratic_to`, `:cubic_to` or `:close_path`, and
`points` are in the font's scale units.

```julia
draw_glyph(font, gid) do op, points
    op === :move_to && move(points[1]...)
end
```
"""
function draw_glyph(f, font::Font, glyph::Integer)
    sink = _DrawSink(f)
    GC.@preserve sink begin
        ccall((:hb_font_draw_glyph, libhb), Cvoid,
              (Ptr{Cvoid}, UInt32, Ptr{Cvoid}, Ptr{Cvoid}),
              font.ptr, UInt32(glyph), _DRAW_FUNCS[], pointer_from_objref(sink))
    end
    return nothing
end

"""
    outline(font::Font, glyph) -> Vector{PathCommand}

The glyph's outline as a list of path commands. Empty for a glyph that
draws nothing, such as a space.

```julia
for cmd in outline(font, gid)
    cmd.op === :line_to && println(cmd.points[1])
end
```
"""
function outline(font::Font, glyph::Integer)::Vector{PathCommand}
    path = PathCommand[]
    draw_glyph(font, glyph) do op, points
        push!(path, PathCommand(op, points))
    end
    return path
end

# --- Colour ---------------------------------------------------------------

"""
    Color

One entry of a CPAL palette. HarfBuzz stores colours as BGRA; the fields
here are the usual four channels.
"""
struct Color
    blue::UInt8
    green::UInt8
    red::UInt8
    alpha::UInt8
end

"""
    has_color_palettes(face::Face) -> Bool
    has_color_layers(face::Face) -> Bool
    has_color_paint(face::Face) -> Bool
    has_color_png(face::Face) -> Bool
    has_color_svg(face::Face) -> Bool

Which colour mechanisms a face carries: CPAL palettes, COLRv0 layers,
COLRv1 paint graphs, embedded PNG bitmaps (CBDT), or SVG documents.
"""
has_color_palettes(f::Face)::Bool =
    ccall((:hb_ot_color_has_palettes, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

has_color_layers(f::Face)::Bool =
    ccall((:hb_ot_color_has_layers, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

has_color_paint(f::Face)::Bool =
    ccall((:hb_ot_color_has_paint, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

has_color_png(f::Face)::Bool =
    ccall((:hb_ot_color_has_png, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

has_color_svg(f::Face)::Bool =
    ccall((:hb_ot_color_has_svg, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

"""
    color_palette_count(face::Face) -> Int

How many CPAL palettes the face offers.
"""
color_palette_count(f::Face)::Int = Int(
    ccall((:hb_ot_color_palette_get_count, libhb), Cuint, (Ptr{Cvoid},), f.ptr))

"""
    color_palette(face::Face, index = 0) -> Vector{Color}

The colours of one palette.
"""
function color_palette(f::Face, index::Integer = 0)::Vector{Color}
    n = Ref{Cuint}(0)
    # Probing with a NULL array returns the total in the return value and
    # leaves the count untouched, so read the former.
    count = Int(ccall((:hb_ot_color_palette_get_colors, libhb), Cuint,
                      (Ptr{Cvoid}, Cuint, Cuint, Ref{Cuint}, Ptr{Cvoid}),
                      f.ptr, Cuint(index), Cuint(0), n, C_NULL))
    count == 0 && return Color[]
    n[] = Cuint(count)
    out = Vector{Color}(undef, count)
    GC.@preserve out begin
        ccall((:hb_ot_color_palette_get_colors, libhb), Cuint,
              (Ptr{Cvoid}, Cuint, Cuint, Ref{Cuint}, Ptr{Cvoid}),
              f.ptr, Cuint(index), Cuint(0), n, pointer(out))
    end
    return out[1:Int(n[])]
end

const _PALETTE_FLAGS = (
    :usable_with_light_background => UInt32(0x0001),
    :usable_with_dark_background => UInt32(0x0002),
)

"""
    color_palette_flags(face::Face, index = 0) -> Vector{Symbol}

What the font says a palette is suitable for:
`:usable_with_light_background`, `:usable_with_dark_background`, or
neither.
"""
color_palette_flags(f::Face, index::Integer = 0)::Vector{Symbol} =
    _flags_symbols(ccall((:hb_ot_color_palette_get_flags, libhb), Cuint,
                         (Ptr{Cvoid}, Cuint), f.ptr, Cuint(index)),
                   _PALETTE_FLAGS)

struct _HbOtColorLayerRaw
    glyph::UInt32
    color_index::UInt32
end

"""
    glyph_color_layers(face::Face, glyph) -> Vector{NamedTuple}

The COLRv0 layers of a glyph, each `(glyph, color_index)`. Empty for a
font that paints through COLRv1 instead.
"""
function glyph_color_layers(f::Face, glyph::Integer)
    n = Ref{Cuint}(0)
    count = Int(ccall((:hb_ot_color_glyph_get_layers, libhb), Cuint,
                      (Ptr{Cvoid}, UInt32, Cuint, Ref{Cuint}, Ptr{Cvoid}),
                      f.ptr, UInt32(glyph), Cuint(0), n, C_NULL))
    count == 0 && return NamedTuple[]
    n[] = Cuint(count)
    buf = Vector{_HbOtColorLayerRaw}(undef, count)
    GC.@preserve buf begin
        ccall((:hb_ot_color_glyph_get_layers, libhb), Cuint,
              (Ptr{Cvoid}, UInt32, Cuint, Ref{Cuint}, Ptr{Cvoid}),
              f.ptr, UInt32(glyph), Cuint(0), n, pointer(buf))
    end
    return [(glyph = Int(l.glyph), color_index = Int(l.color_index))
            for l in buf[1:Int(n[])]]
end

"""
    glyph_has_color_paint(face::Face, glyph) -> Bool

True when the glyph has a COLRv1 paint graph.
"""
glyph_has_color_paint(f::Face, glyph::Integer)::Bool =
    ccall((:hb_ot_color_glyph_has_paint, libhb), Cint,
          (Ptr{Cvoid}, UInt32), f.ptr, UInt32(glyph)) != 0

"""
    glyph_color_png(font::Font, glyph) -> Blob
    glyph_color_svg(face::Face, glyph) -> Blob

The embedded PNG or SVG document for a colour glyph. The blob is empty
when the font carries none.
"""
function glyph_color_png(font::Font, glyph::Integer)::Blob
    ptr = ccall((:hb_ot_color_glyph_reference_png, libhb), Ptr{Cvoid},
                (Ptr{Cvoid}, UInt32), font.ptr, UInt32(glyph))
    blob = Blob(ptr, nothing)
    finalizer(_blob_destroy, blob)
    return blob
end

function glyph_color_svg(f::Face, glyph::Integer)::Blob
    ptr = ccall((:hb_ot_color_glyph_reference_svg, libhb), Ptr{Cvoid},
                (Ptr{Cvoid}, UInt32), f.ptr, UInt32(glyph))
    blob = Blob(ptr, nothing)
    finalizer(_blob_destroy, blob)
    return blob
end

# --- Math -----------------------------------------------------------------

const _MATH_CONSTANTS = (
    :script_percent_scale_down, :script_script_percent_scale_down,
    :delimited_sub_formula_min_height, :display_operator_min_height,
    :math_leading, :axis_height, :accent_base_height,
    :flattened_accent_base_height, :subscript_shift_down,
    :subscript_top_max, :subscript_baseline_drop_min, :superscript_shift_up,
    :superscript_shift_up_cramped, :superscript_bottom_min,
    :superscript_baseline_drop_max, :sub_superscript_gap_min,
    :superscript_bottom_max_with_subscript, :space_after_script,
    :upper_limit_gap_min, :upper_limit_baseline_rise_min,
    :lower_limit_gap_min, :lower_limit_baseline_drop_min, :stack_top_shift_up,
    :stack_top_display_style_shift_up, :stack_bottom_shift_down,
    :stack_bottom_display_style_shift_down, :stack_gap_min,
    :stack_display_style_gap_min, :stretch_stack_top_shift_up,
    :stretch_stack_bottom_shift_down, :stretch_stack_gap_above_min,
    :stretch_stack_gap_below_min, :fraction_numerator_shift_up,
    :fraction_numerator_display_style_shift_up,
    :fraction_denominator_shift_down,
    :fraction_denominator_display_style_shift_down,
    :fraction_numerator_gap_min, :fraction_num_display_style_gap_min,
    :fraction_rule_thickness, :fraction_denominator_gap_min,
    :fraction_denom_display_style_gap_min, :skewed_fraction_horizontal_gap,
    :skewed_fraction_vertical_gap, :overbar_vertical_gap,
    :overbar_rule_thickness, :overbar_extra_ascender, :underbar_vertical_gap,
    :underbar_rule_thickness, :underbar_extra_descender, :radical_vertical_gap,
    :radical_display_style_vertical_gap, :radical_rule_thickness,
    :radical_extra_ascender, :radical_kern_before_degree,
    :radical_kern_after_degree, :radical_degree_bottom_raise_percent,
)

"""
    has_math_data(face::Face) -> Bool

True when the face carries a `MATH` table.
"""
has_math_data(f::Face)::Bool =
    ccall((:hb_ot_math_has_data, libhb), Cint, (Ptr{Cvoid},), f.ptr) != 0

"""
    math_constant(font::Font, name::Symbol) -> Int32

One of the `MATH` table's layout constants, such as `:axis_height`,
`:fraction_rule_thickness` or `:radical_rule_thickness`. Percentages come
back as integers; everything else is in the font's scale units.
"""
function math_constant(f::Font, name::Symbol)::Int32
    i = findfirst(==(name), _MATH_CONSTANTS)
    i === nothing && throw(ArgumentError(
        "unknown math constant :$name; see HarfBuzz's hb_ot_math_constant_t"))
    return ccall((:hb_ot_math_get_constant, libhb), Int32,
                 (Ptr{Cvoid}, Cint), f.ptr, Cint(i - 1))
end

"""
    math_italics_correction(font::Font, glyph) -> Int32

Space to add after a slanted glyph so a following subscript does not
collide with it.
"""
math_italics_correction(f::Font, glyph::Integer)::Int32 =
    ccall((:hb_ot_math_get_glyph_italics_correction, libhb), Int32,
          (Ptr{Cvoid}, UInt32), f.ptr, UInt32(glyph))

"""
    math_top_accent_attachment(font::Font, glyph) -> Int32

Horizontal position an accent should be centred on.
"""
math_top_accent_attachment(f::Font, glyph::Integer)::Int32 =
    ccall((:hb_ot_math_get_glyph_top_accent_attachment, libhb), Int32,
          (Ptr{Cvoid}, UInt32), f.ptr, UInt32(glyph))

"""
    is_math_extended_shape(face::Face, glyph) -> Bool

True for glyphs that grow with the formula, such as big parentheses.
"""
is_math_extended_shape(f::Face, glyph::Integer)::Bool =
    ccall((:hb_ot_math_is_glyph_extended_shape, libhb), Cint,
          (Ptr{Cvoid}, UInt32), f.ptr, UInt32(glyph)) != 0

"""
    math_min_connector_overlap(font::Font; direction = :ttb) -> Int32

Minimum overlap between the pieces of an assembled stretchy glyph.
"""
math_min_connector_overlap(f::Font; direction::Symbol = :ttb)::Int32 =
    ccall((:hb_ot_math_get_min_connector_overlap, libhb), Int32,
          (Ptr{Cvoid}, Cint), f.ptr, _direction_value(direction))

struct _HbOtMathGlyphVariantRaw
    glyph::UInt32
    advance::Int32
end

struct _HbOtMathGlyphPartRaw
    glyph::UInt32
    start_connector_length::Int32
    end_connector_length::Int32
    full_advance::Int32
    flags::UInt32
end

"""
    math_glyph_variants(font::Font, glyph; direction = :ttb) -> Vector{NamedTuple}

The ready-made larger versions of a stretchy glyph, each
`(glyph, advance)`, in increasing size.
"""
function math_glyph_variants(f::Font, glyph::Integer; direction::Symbol = :ttb)
    n = Ref{Cuint}(0)
    total = ccall((:hb_ot_math_get_glyph_variants, libhb), Cuint,
                  (Ptr{Cvoid}, UInt32, Cint, Cuint, Ref{Cuint}, Ptr{Cvoid}),
                  f.ptr, UInt32(glyph), _direction_value(direction),
                  Cuint(0), n, C_NULL)
    total == 0 && return NamedTuple[]
    buf = Vector{_HbOtMathGlyphVariantRaw}(undef, Int(total))
    n[] = Cuint(total)
    GC.@preserve buf begin
        ccall((:hb_ot_math_get_glyph_variants, libhb), Cuint,
              (Ptr{Cvoid}, UInt32, Cint, Cuint, Ref{Cuint}, Ptr{Cvoid}),
              f.ptr, UInt32(glyph), _direction_value(direction),
              Cuint(0), n, pointer(buf))
    end
    return [(glyph = Int(v.glyph), advance = v.advance) for v in buf[1:Int(n[])]]
end

"""
    math_glyph_assembly(font::Font, glyph; direction = :ttb) -> NamedTuple

How to build an arbitrarily large version of a stretchy glyph out of
pieces: `(parts, italics_correction)`, where each part is
`(glyph, start_connector_length, end_connector_length, full_advance,
extender)`.
"""
function math_glyph_assembly(f::Font, glyph::Integer; direction::Symbol = :ttb)
    n = Ref{Cuint}(0)
    italics = Ref{Int32}(0)
    total = ccall((:hb_ot_math_get_glyph_assembly, libhb), Cuint,
                  (Ptr{Cvoid}, UInt32, Cint, Cuint, Ref{Cuint}, Ptr{Cvoid},
                   Ref{Int32}),
                  f.ptr, UInt32(glyph), _direction_value(direction),
                  Cuint(0), n, C_NULL, italics)
    total == 0 && return (parts = NamedTuple[], italics_correction = italics[])
    buf = Vector{_HbOtMathGlyphPartRaw}(undef, Int(total))
    n[] = Cuint(total)
    GC.@preserve buf begin
        ccall((:hb_ot_math_get_glyph_assembly, libhb), Cuint,
              (Ptr{Cvoid}, UInt32, Cint, Cuint, Ref{Cuint}, Ptr{Cvoid},
               Ref{Int32}),
              f.ptr, UInt32(glyph), _direction_value(direction),
              Cuint(0), n, pointer(buf), italics)
    end
    parts = [(glyph = Int(p.glyph),
              start_connector_length = p.start_connector_length,
              end_connector_length = p.end_connector_length,
              full_advance = p.full_advance,
              extender = p.flags & 0x1 != 0) for p in buf[1:Int(n[])]]
    return (parts = parts, italics_correction = italics[])
end

# --- Subsetting -----------------------------------------------------------

const libhb_subset = HarfBuzz_jll.libharfbuzz_subset_path

const _SUBSET_FLAGS = (
    :no_hinting => UInt32(0x0001),
    :retain_gids => UInt32(0x0002),
    :desubroutinize => UInt32(0x0004),
    :name_legacy => UInt32(0x0008),
    :set_overlaps_flag => UInt32(0x0010),
    :passthrough_unrecognized => UInt32(0x0020),
    :notdef_outline => UInt32(0x0040),
    :glyph_names => UInt32(0x0080),
    :no_prune_unicode_ranges => UInt32(0x0100),
    :no_layout_closure => UInt32(0x0200),
    :optimize_iup_deltas => UInt32(0x0400),
)

"""
    subset(face::Face; unicodes = nothing, glyphs = nothing,
           flags = Symbol[]) -> Face

Cut a face down to the codepoints or glyphs given, returning a new face
backed by freshly generated font data.

Flags: $(join(map(p -> ":" * String(p.first), _SUBSET_FLAGS), ", ")).
`:glyph_names` is worth knowing about — without it the `post` table's
glyph names are dropped, so [`glyph_name`](@ref) returns `nothing` on the
result.

```julia
small = subset(face; unicodes = UInt32.(collect("Hello")))
write("hello.ttf", data(small._blob))
```
"""
function subset(f::Face; unicodes = nothing, glyphs = nothing,
                flags = Symbol[])::Face
    input = ccall((:hb_subset_input_create_or_fail, libhb_subset),
                  Ptr{Cvoid}, ())
    input == C_NULL && throw(ErrorException("hb_subset_input_create_or_fail failed"))
    try
        bits = _flags_value(flags, _SUBSET_FLAGS, "subset flag")
        bits == 0 || ccall((:hb_subset_input_set_flags, libhb_subset), Cvoid,
                           (Ptr{Cvoid}, Cuint), input, Cuint(bits))
        if unicodes !== nothing
            set = ccall((:hb_subset_input_unicode_set, libhb_subset),
                        Ptr{Cvoid}, (Ptr{Cvoid},), input)
            for cp in unicodes
                ccall((:hb_set_add, libhb), Cvoid,
                      (Ptr{Cvoid}, UInt32), set, UInt32(cp))
            end
        end
        if glyphs !== nothing
            set = ccall((:hb_subset_input_glyph_set, libhb_subset),
                        Ptr{Cvoid}, (Ptr{Cvoid},), input)
            for g in glyphs
                ccall((:hb_set_add, libhb), Cvoid,
                      (Ptr{Cvoid}, UInt32), set, UInt32(g))
            end
        end

        ptr = ccall((:hb_subset_or_fail, libhb_subset), Ptr{Cvoid},
                    (Ptr{Cvoid}, Ptr{Cvoid}), f.ptr, input)
        ptr == C_NULL && throw(ErrorException("hb_subset_or_fail failed"))

        # Materialise the result so the new face owns its bytes rather than
        # referring back to the source face.
        blob_ptr = ccall((:hb_face_reference_blob, libhb), Ptr{Cvoid},
                         (Ptr{Cvoid},), ptr)
        ccall((:hb_face_destroy, libhb), Cvoid, (Ptr{Cvoid},), ptr)
        blob = Blob(blob_ptr, nothing)
        finalizer(_blob_destroy, blob)
        return Face(blob)
    finally
        ccall((:hb_subset_input_destroy, libhb_subset), Cvoid,
              (Ptr{Cvoid},), input)
    end
end

# --- Module initialisation ------------------------------------------------

function __init__()
    atexit(() -> _EXITING[] = true)
    # Built here rather than at top level so no function pointer is baked
    # into the precompilation image.
    _MESSAGE_CFUNC[] = @cfunction(_message_trampoline, Cint,
                                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{Cvoid}))
    _init_draw_funcs()
    return nothing
end

end # module
