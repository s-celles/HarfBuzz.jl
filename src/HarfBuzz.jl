module HarfBuzz

using HarfBuzz_jll
import FreeType

const libhb = HarfBuzz_jll.libharfbuzz_path

# --- Opaque pointer types ------------------------------------------------

"""
    HbBlob

An opaque handle to a `hb_blob_t` — a reference-counted blob of binary
font data. Created from a file or memory, passed to `hb_face_create`.
"""
mutable struct HbBlob
    ptr::Ptr{Cvoid}
end

"""
    HbFace

An opaque handle to a `hb_face_t` — a font face. Created from a blob
and a face index (0 for non-collection fonts).
"""
mutable struct HbFace
    ptr::Ptr{Cvoid}
end

"""
    HbFont

An opaque handle to a `hb_font_t` — a scaled font. Created from a face
with a scale set via `hb_font_set_scale`.
"""
mutable struct HbFont
    ptr::Ptr{Cvoid}
    # FreeType face backing this font (kept alive to prevent GC of
    # the FT_Face that hb_ft_font_create references).
    ft_face::Ptr{FreeType.FT_FaceRec_}
    ft_library::Ptr{FreeType.FT_LibraryRec_}
end

"""
    HbBuffer

An opaque handle to a `hb_buffer_t` — the input/output container for
text shaping. Holds codepoints before shaping and glyph infos +
positions after shaping.
"""
mutable struct HbBuffer
    ptr::Ptr{Cvoid}
end

# --- Reference counting ---------------------------------------------------

# HarfBuzz uses refcounting. Each create returns refcount=1; _reference
# increments, _destroy decrements. We use finalizers to auto-destroy.

function _hb_blob_reference(b::HbBlob)
    ccall((:hb_blob_reference, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), b.ptr)
    nothing
end

function _hb_blob_destroy(b::HbBlob)
    b.ptr == C_NULL || ccall((:hb_blob_destroy, libhb), Cvoid, (Ptr{Cvoid},), b.ptr)
    b.ptr = C_NULL
    nothing
end

function _hb_face_reference(f::HbFace)
    ccall((:hb_face_reference, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), f.ptr)
    nothing
end

function _hb_face_destroy(f::HbFace)
    f.ptr == C_NULL || ccall((:hb_face_destroy, libhb), Cvoid, (Ptr{Cvoid},), f.ptr)
    f.ptr = C_NULL
    nothing
end

function _hb_font_reference(f::HbFont)
    ccall((:hb_font_reference, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), f.ptr)
    nothing
end

function _hb_font_destroy(f::HbFont)
    # Leak intentionally: destroying hb_font_t that wraps a FT_Face
    # segfaults on macOS ARM64 because FreeType.jl's struct layout
    # does not match the JLL's expectations. The leak is bounded (one
    # font per HbFont creation) and acceptable for a shaping library
    # used at startup time.
    f.ptr = C_NULL
    nothing
end

function _hb_buffer_reference(b::HbBuffer)
    ccall((:hb_buffer_reference, libhb), Ptr{Cvoid}, (Ptr{Cvoid},), b.ptr)
    nothing
end

function _hb_buffer_destroy(b::HbBuffer)
    b.ptr == C_NULL || ccall((:hb_buffer_destroy, libhb), Cvoid, (Ptr{Cvoid},), b.ptr)
    b.ptr = C_NULL
    nothing
end

# --- hb_blob_t ------------------------------------------------------------

"""
    HbBlob(path::AbstractString)

Create a blob from a file. The blob is marked read-only and is
mmap-friendly (HarfBuzz uses `HB_MEMORY_MODE_READONLY`).
"""
function HbBlob(path::AbstractString)::HbBlob
    isfile(path) || throw(ArgumentError("font file not found: $path"))
    # hb_blob_create_from_file returns a blob or an empty blob (never NULL).
    # An empty blob has length 0, which we check after creation.
    ptr = ccall((:hb_blob_create_from_file, libhb),
                Ptr{Cvoid}, (Cstring,), String(path))
    ptr == C_NULL && throw(ErrorException("hb_blob_create_from_file failed: $path"))
    blob = HbBlob(ptr)
    finalizer(_hb_blob_destroy, blob)
    return blob
end

# --- hb_face_t ------------------------------------------------------------

"""
    HbFace(blob::HbBlob, index::Integer=0)

Create a face from a blob. `index` selects the face in a TTC
(TrueType Collection); 0 is the first face.
"""
function HbFace(blob::HbBlob, index::Integer = 0)::HbFace
    ptr = ccall((:hb_face_create, libhb),
                Ptr{Cvoid}, (Ptr{Cvoid}, Cuint), blob.ptr, Cuint(index))
    ptr == C_NULL && throw(ErrorException("hb_face_create failed"))
    face = HbFace(ptr)
    finalizer(_hb_face_destroy, face)
    return face
end

"""
    HbFace(path::AbstractString, index::Integer=0)

Convenience: create a blob from `path` then a face from that blob.
"""
function HbFace(path::AbstractString, index::Integer = 0)::HbFace
    return HbFace(HbBlob(path), index)
end

# --- hb_font_t ------------------------------------------------------------

"""
    HbFont(face::HbFace; x_scale::Int=0, y_scale::Int=0)

Create a font from a face. `x_scale` and `y_scale` are in 16.16
fixed-point: for an 18px font, pass `18 * 64 = 1152` (or use the
`size` keyword which does the conversion).
"""
function HbFont(face::HbFace; x_scale::Int = 0, y_scale::Int = 0)::HbFont
    ptr = ccall((:hb_font_create, libhb),
                Ptr{Cvoid}, (Ptr{Cvoid},), face.ptr)
    ptr == C_NULL && throw(ErrorException("hb_font_create failed"))
    font = HbFont(ptr, C_NULL, C_NULL)
    finalizer(_hb_font_destroy, font)
    if x_scale != 0 || y_scale != 0
        set_scale!(font, x_scale, y_scale)
    end
    return font
end

"""
    HbFont(face::HbFace, size::Integer)

Create a font at `size` pixels. The scale is `size * 64` (16.16
fixed-point, the convention HarfBuzz uses for FreeType-compatible
scaling).
"""
function HbFont(face::HbFace, size::Integer)::HbFont
    s = Int(size) * 64
    font = HbFont(face; x_scale = s, y_scale = s)
    return font
end

"""
    HbFont(path::AbstractString, size::Integer; index::Integer=0)

Convenience: open a font file via FreeType, create a HarfBuzz font
from the FT_Face so that glyph advances are available. This is the
recommended way to create a font for shaping — without FreeType
backing, HarfBuzz cannot obtain advances or glyph outlines.
"""
function HbFont(path::AbstractString, size::Integer; index::Integer = 0)::HbFont
    # Open the font via FreeType
    ft_library = Ref{Ptr{FreeType.FT_LibraryRec_}}()
    err = FreeType.FT_Init_FreeType(ft_library)
    err != 0 && throw(ErrorException("FT_Init_FreeType failed: $err"))

    ft_face = Ref{Ptr{FreeType.FT_FaceRec_}}()
    err = FreeType.FT_New_Face(ft_library[], String(path), Clong(index), ft_face)
    err != 0 && throw(ErrorException("FT_New_Face failed for $path: $err"))

    # Set the char size (in 1/64th of a pixel)
    char_size = Int(size) * 64
    err = FreeType.FT_Set_Char_Size(ft_face[], 0, char_size, 0, 0)
    err != 0 && throw(ErrorException("FT_Set_Char_Size failed: $err"))

    # Create a HarfBuzz font from the FT_Face
    ptr = ccall((:hb_ft_font_create, libhb),
                Ptr{Cvoid}, (Ptr{Cvoid},), ft_face[])
    ptr == C_NULL && throw(ErrorException("hb_ft_font_create failed"))

    # Explicitly set FreeType font functions. In some HarfBuzz versions
    # hb_ft_font_create does not call hb_ft_font_set_funcs automatically,
    # which results in zero glyph advances.
    ccall((:hb_ft_font_set_funcs, libhb), Cvoid, (Ptr{Cvoid},), ptr)

    font = HbFont(ptr, ft_face[], ft_library[])
    finalizer(_hb_font_destroy, font)
    return font
end

"""
    set_scale!(font::HbFont, x_scale::Int, y_scale::Int)

Set the font scale in 16.16 fixed-point.
"""
function set_scale!(font::HbFont, x_scale::Int, y_scale::Int)::Nothing
    ccall((:hb_font_set_scale, libhb), Cvoid,
          (Ptr{Cvoid}, Cint, Cint), font.ptr, Cint(x_scale), Cint(y_scale))
    return nothing
end

# --- hb_buffer_t ----------------------------------------------------------

"""
    HbBuffer()

Create an empty buffer. Add text with `add_text!`, then call `shape!`.
"""
function HbBuffer()::HbBuffer
    ptr = ccall((:hb_buffer_create, libhb), Ptr{Cvoid}, ())
    ptr == C_NULL && throw(ErrorException("hb_buffer_create failed"))
    buf = HbBuffer(ptr)
    finalizer(_hb_buffer_destroy, buf)
    return buf
end

"""
    clear!(buf::HbBuffer)

Reset the buffer to empty, discarding all content and state.
"""
function clear!(buf::HbBuffer)::Nothing
    ccall((:hb_buffer_clear_contents, libhb), Cvoid, (Ptr{Cvoid},), buf.ptr)
    return nothing
end

"""
    add_text!(buf::HbBuffer, text::AbstractString)

Add UTF-8 text to the buffer. The buffer must be cleared between
shaping runs; this does not clear automatically.
"""
function add_text!(buf::HbBuffer, text::AbstractString)::Nothing
    bytes = codeunits(String(text))
    n = length(bytes)
    # HB_MEMORY_MODE_WRITABLE = 2 — HarfBuzz copies the data internally
    # when mode is WRITABLE, so it is safe to pass a Julia-owned array.
    GC.@preserve bytes begin
        ccall((:hb_buffer_add_utf8, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{UInt8}, Cint, Cuint, Cint),
              buf.ptr, pointer(bytes), Cint(n), Cuint(0), Cint(-1))
    end
    return nothing
end

"""
    guess_segment_properties!(buf::HbBuffer)

Ask HarfBuzz to guess script, language and direction from the buffer
content. This is the standard call before `shape!` when the caller
does not know the script.
"""
function guess_segment_properties!(buf::HbBuffer)::Nothing
    ccall((:hb_buffer_guess_segment_properties, libhb), Cvoid,
          (Ptr{Cvoid},), buf.ptr)
    return nothing
end

# --- Shaping result -------------------------------------------------------

"""
    GlyphInfo

One entry from `hb_buffer_get_glyph_infos`. `glyph_id` is the font's
internal glyph index (not a Unicode codepoint); `cluster` is the byte
offset of the start of the cluster this glyph belongs to.
"""
struct GlyphInfo
    glyph_id::UInt32
    cluster::UInt32
end

"""
    GlyphPosition

One entry from `hb_buffer_get_glyph_positions`. All values are in
26.6 fixed-point (1/64 pixel units). `x_advance` and `y_advance` are
the pen advance after this glyph; `x_offset` and `y_offset` are the
position offset from the pen.
"""
struct GlyphPosition
    x_advance::Int32
    y_advance::Int32
    x_offset::Int32
    y_offset::Int32
end

"""
    ShapeResult

The output of `shape!`: a vector of glyph infos and a vector of glyph
positions, parallel arrays of the same length.
"""
struct ShapeResult
    infos::Vector{GlyphInfo}
    positions::Vector{GlyphPosition}
end

# hb_glyph_info_t: { uint32 codepoint, uint32 mask, uint32 cluster,
#   uint32 var1, uint32 var2 } — 20 bytes on 64-bit
# hb_glyph_position_t: { int32 x_advance, int32 y_advance,
#   int32 x_offset, int32 y_offset, int32 var1, int32 var2 } — 24 bytes

const _HB_GLYPH_INFO_SIZE = 20
const _HB_GLYPH_POS_SIZE = 24

"""
    shape!(font::HbFont, buf::HbBuffer; features=nothing)

Shape the text in `buf` using `font`. Returns a `ShapeResult` with
glyph infos and positions. The buffer must have text added and
segment properties guessed (or set) before calling this.

`features` is an optional vector of `(name, value)` pairs, e.g.
`[("liga", 1)]` to enable ligatures. Pass `nothing` for defaults.
"""
function shape!(font::HbFont, buf::HbBuffer;
                features::Union{Nothing,Vector{Tuple{String,Int}}} = nothing)::ShapeResult
    # Shape
    if features === nothing
        ccall((:hb_shape, libhb), Cvoid,
              (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cuint),
              font.ptr, buf.ptr, C_NULL, Cuint(0))
    else
        # Build hb_feature_t array: { uint32 tag, uint32 value,
        #   uint32 start, uint32 end } — 16 bytes each
        nfeat = length(features)
        feat_arr = Vector{NTuple{4,UInt32}}(undef, nfeat)
        for (i, (name, val)) in enumerate(features)
            # Convert feature name to 4-char tag (HarfBuzz tag)
            tag = _name_to_tag(name)
            feat_arr[i] = (tag, UInt32(val), UInt32(0), UInt32(0))
        end
        GC.@preserve feat_arr begin
            ccall((:hb_shape, libhb), Cvoid,
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cuint),
                  font.ptr, buf.ptr, pointer(feat_arr), Cuint(nfeat))
        end
    end

    # Read results
    n_info = Ref{Cuint}(0)
    info_ptr = ccall((:hb_buffer_get_glyph_infos, libhb),
                     Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Cuint}), buf.ptr, n_info)
    n = Int(n_info[])

    n_pos = Ref{Cuint}(0)
    pos_ptr = ccall((:hb_buffer_get_glyph_positions, libhb),
                    Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Cuint}), buf.ptr, n_pos)
    @assert n == Int(n_pos[]) "glyph info/position count mismatch"

    infos = Vector{GlyphInfo}(undef, n)
    for i in 1:n
        base = info_ptr + (i - 1) * _HB_GLYPH_INFO_SIZE
        # hb_glyph_info_t: { uint32 codepoint, uint32 mask, uint32 cluster, ... }
        glyph_id = unsafe_load(convert(Ptr{UInt32}, base))         # offset 0
        cluster = unsafe_load(convert(Ptr{UInt32}, base + 8))     # offset 8
        infos[i] = GlyphInfo(glyph_id, cluster)
    end

    positions = Vector{GlyphPosition}(undef, n)
    for i in 1:n
        base = pos_ptr + (i - 1) * _HB_GLYPH_POS_SIZE
        xa = unsafe_load(convert(Ptr{Int32}, base))
        ya = unsafe_load(convert(Ptr{Int32}, base + 4))
        xo = unsafe_load(convert(Ptr{Int32}, base + 8))
        yo = unsafe_load(convert(Ptr{Int32}, base + 12))
        positions[i] = GlyphPosition(xa, ya, xo, yo)
    end

    return ShapeResult(infos, positions)
end

# Convert a 4-char feature name to a HarfBuzz tag (UInt32, big-endian
# 4 bytes). E.g. "liga" -> 0x6C696761.
function _name_to_tag(name::AbstractString)::UInt32
    s = String(name)
    len = sizeof(s)
    tag = UInt32(0)
    for i in 1:4
        c = i <= len ? UInt8(s[i]) : UInt8(' ')
        tag = (tag << 8) | UInt32(c)
    end
    return tag
end

# --- Convenience ----------------------------------------------------------

"""
    shape(font::HbFont, text::AbstractString; features=nothing) -> ShapeResult

One-shot convenience: create a buffer, add text, guess segment
properties, shape, and return the result. The buffer is destroyed
afterwards.

Note: glyph advances may be zero when using `HbFont(path, size)` due to
a FreeType.jl / HarfBuzz integration issue. Use `glyph_ids` and
`clusters` for text shaping logic, and measure advances via the
renderer (e.g. ImGui's `CalcTextSize` or a fixed cell width for
monospace fonts).
"""
function shape(font::HbFont, text::AbstractString;
               features::Union{Nothing,Vector{Tuple{String,Int}}} = nothing)::ShapeResult
    buf = HbBuffer()
    add_text!(buf, text)
    guess_segment_properties!(buf)
    result = shape!(font, buf; features = features)
    return result
end

"""
    glyph_ids(result::ShapeResult) -> Vector{UInt32}

Extract just the glyph IDs from a shaping result.
"""
glyph_ids(result::ShapeResult) = [g.glyph_id for g in result.infos]

"""
    clusters(result::ShapeResult) -> Vector{UInt32}

Extract just the cluster byte offsets from a shaping result.
"""
clusters(result::ShapeResult) = [g.cluster for g in result.infos]

# --- Font functions needed for fallback -----------------------------------

"""
    get_glyph_count(face::HbFace) -> Int

Number of glyphs in the face.
"""
function get_glyph_count(face::HbFace)::Int
    n = ccall((:hb_face_get_glyph_count, libhb), Cuint, (Ptr{Cvoid},), face.ptr)
    return Int(n)
end

"""
    get_nominal_glyph(font::HbFont, unicode::UInt32) -> UInt32

Return the glyph ID for a Unicode codepoint, or 0 if the font does
not contain it. This is the HarfBuzz equivalent of
"does this font have this character?".
"""
function get_nominal_glyph(font::HbFont, unicode::UInt32)::UInt32
    glyph = Ref{UInt32}(0)
    found = ccall((:hb_font_get_glyph, libhb), Cint,
                  (Ptr{Cvoid}, UInt32, UInt32, Ref{UInt32}),
                  font.ptr, unicode, UInt32(0), glyph)
    return found != 0 ? glyph[] : UInt32(0)
end

"""
    has_glyph(font::HbFont, unicode::UInt32) -> Bool

True if the font contains a glyph for `unicode`.
"""
has_glyph(font::HbFont, unicode::UInt32)::Bool = get_nominal_glyph(font, unicode) != 0

export HbBlob, HbFace, HbFont, HbBuffer,
       GlyphInfo, GlyphPosition, ShapeResult,
       clear!, add_text!, guess_segment_properties!, set_scale!,
       shape!, shape, glyph_ids, clusters,
       get_glyph_count, get_nominal_glyph, has_glyph

end # module