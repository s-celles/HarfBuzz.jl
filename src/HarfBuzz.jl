module HarfBuzz

using HarfBuzz_jll

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

# Anything a caller may pass in `features = [...]`.
_as_feature(f::Feature) = f
_as_feature(s::AbstractString) = Feature(s)
_as_feature(t::Tuple{AbstractString,Integer}) = _make_feature(t[1], t[2])
_as_feature(p::Pair{<:AbstractString,<:Integer}) = _make_feature(p.first, p.second)

"""
    shape!(font::Font, buf::Buffer; features = nothing, shapers = nothing)

Shape the text in `buf` using `font`. Returns a `ShapeResult` with
glyph infos and positions.

`features` accepts [`Feature`](@ref) values, HarfBuzz feature strings, or
`name => value` pairs. `shapers` restricts which backends may be tried, in
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
result = shape(font, "AVATAR"; features = [("kern", 0)])
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
    endptr = Ref{Ptr{UInt8}}(C_NULL)
    ok = ccall((:hb_buffer_deserialize_glyphs, libhb), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, Cint, Ref{Ptr{UInt8}}, Ptr{Cvoid}, UInt32),
               buf.ptr, String(text), Cint(sizeof(text)), endptr, fontptr, fmt)
    ok == 0 && throw(ArgumentError("cannot parse serialized glyphs"))
    return buf
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

# --- Module initialisation ------------------------------------------------

function __init__()
    atexit(() -> _EXITING[] = true)
    # Built here rather than at top level so no function pointer is baked
    # into the precompilation image.
    _MESSAGE_CFUNC[] = @cfunction(_message_trampoline, Cint,
                                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Ptr{Cvoid}))
    return nothing
end

end # module
