module HarfBuzz

using HarfBuzz_jll
import FreeType
import FreeTypeAbstraction

const libhb = HarfBuzz_jll.libharfbuzz_path

# Shared FreeType library handle. Initialised in `__init__` so that no
# pointer is baked into the precompilation image.
const _FT_LIBRARY = Ref{Ptr{FreeType.FT_LibraryRec_}}(C_NULL)

# Set once the process starts shutting down. See `_hb_font_destroy`.
const _EXITING = Ref(false)

function __init__()
    lib = Ref{Ptr{FreeType.FT_LibraryRec_}}()
    err = FreeType.FT_Init_FreeType(lib)
    err != 0 && throw(ErrorException("FT_Init_FreeType failed: $err"))
    _FT_LIBRARY[] = lib[]
    atexit(() -> _EXITING[] = true)
    return nothing
end

# --- Opaque pointer types ------------------------------------------------

mutable struct HbFont
    ptr::Ptr{Cvoid}
    # FreeType face pointer (C-level). Kept for hb_ft_font_create.
    ft_face::Ptr{FreeType.FT_FaceRec_}
    ft_library::Ptr{FreeType.FT_LibraryRec_}
    # Anchor: the Julia-side FTFont object from FreeTypeAbstraction.
    # Prevents GC from collecting it (and the FT_Face it owns) while
    # the HarfBuzz font is alive.
    _anchor::Any
end

mutable struct HbBuffer
    ptr::Ptr{Cvoid}
end

# --- Reference counting ---------------------------------------------------

function _hb_font_destroy(f::HbFont)
    # `hb_ft_font_create_referenced` installed FT_Done_Face as the
    # destroy callback, so this also releases the reference taken on the
    # FT_Face.
    #
    # Skip it at process teardown: Julia runs atexit hooks before the
    # final round of finalizers, and FreeTypeAbstraction's hook calls
    # FT_Done_FreeType, which frees every face its library owns. Calling
    # FT_Done_Face afterwards is a use-after-free. Leaking here costs
    # nothing -- the process is exiting.
    if f.ptr != C_NULL && !_EXITING[]
        ccall((:hb_font_destroy, libhb), Cvoid, (Ptr{Cvoid},), f.ptr)
    end
    f.ptr = C_NULL
    nothing
end

function _hb_buffer_destroy(b::HbBuffer)
    b.ptr == C_NULL || ccall((:hb_buffer_destroy, libhb), Cvoid, (Ptr{Cvoid},), b.ptr)
    b.ptr = C_NULL
    nothing
end

# --- hb_font_t ------------------------------------------------------------

"""
    HbFont(name::AbstractString, size::Integer; index::Integer=0)

Open a font for HarfBuzz shaping. `name` is either a path to a font
file or a font family name:

- If `name` is an existing file path, the font is opened directly via
  FreeType. `index` selects the face inside a TTC (TrueType
  Collection).
- Otherwise `name` is treated as a family name and resolved
  cross-platform via `FreeTypeAbstraction.findfont` (e.g. `"Menlo"`,
  `"DejaVu Sans Mono"`, `"Consolas"`). `index` is ignored in this
  branch.

The font is opened at `size` pixels.

```julia
font = HbFont("/System/Library/Fonts/Menlo.ttc", 18)
font = HbFont("Menlo", 18)
```
"""
function HbFont(name::AbstractString, size::Integer; index::Integer = 0)::HbFont
    if isfile(String(name))
        # --- Path branch: open the file directly via FreeType ---------
        # FT_New_Face writes a `FT_Face` (== Ptr{__JL_FT_FaceRec_})
        # into the ref; the HbFont.ft_face field (Ptr{FT_FaceRec_})
        # accepts it via the usual pointer reinterpretation.
        face_ref = Ref{FreeType.FT_Face}()
        err = FreeType.FT_New_Face(_FT_LIBRARY[], String(name),
                                   Clong(index), face_ref)
        err != 0 && throw(ErrorException(
            "FT_New_Face failed for $name: $err"))
        ft_face = face_ref[]

        char_size = Int(size) * 64
        err = FreeType.FT_Set_Char_Size(ft_face, 0, char_size, 0, 0)
        if err != 0
            FreeType.FT_Done_Face(ft_face)
            throw(ErrorException("FT_Set_Char_Size failed: $err"))
        end

        # `_referenced` takes its own reference on the FT_Face and
        # installs FT_Done_Face as the destroy callback, so the face
        # outlives this scope and is released with the hb_font_t.
        ptr = ccall((:hb_ft_font_create_referenced, libhb),
                    Ptr{Cvoid}, (Ptr{Cvoid},), ft_face)
        if ptr == C_NULL
            FreeType.FT_Done_Face(ft_face)
            throw(ErrorException("hb_ft_font_create_referenced failed"))
        end
        # Drop the reference taken by FT_New_Face; HarfBuzz holds the
        # remaining one.
        FreeType.FT_Done_Face(ft_face)

        font = HbFont(ptr, ft_face, _FT_LIBRARY[], nothing)
        finalizer(_hb_font_destroy, font)
        return font
    else
        # --- Family branch: resolve via FreeTypeAbstraction -----------
        ftfont = FreeTypeAbstraction.findfont(String(name))
        ftfont === nothing && throw(ErrorException(
            "font not found: '$name'. Searched paths: " *
            join(FreeTypeAbstraction.fontpaths(), ", ")))
        char_size = Int(size) * 64
        err = FreeType.FT_Set_Char_Size(ftfont, 0, char_size, 0, 0)
        err != 0 && throw(ErrorException("FT_Set_Char_Size failed: $err"))
        # The FT_Face belongs to FreeTypeAbstraction's cache, so only the
        # reference taken here is released on destruction.
        ptr = ccall((:hb_ft_font_create_referenced, libhb),
                    Ptr{Cvoid}, (Ptr{Cvoid},), ftfont.ft_ptr)
        ptr == C_NULL && throw(ErrorException(
            "hb_ft_font_create_referenced failed"))
        font = HbFont(ptr, ftfont.ft_ptr, C_NULL, ftfont)
        finalizer(_hb_font_destroy, font)
        return font
    end
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

Add UTF-8 text to the buffer.
"""
function add_text!(buf::HbBuffer, text::AbstractString)::Nothing
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
    guess_segment_properties!(buf::HbBuffer)

Ask HarfBuzz to guess script, language and direction from the buffer
content.
"""
function guess_segment_properties!(buf::HbBuffer)::Nothing
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

Per-glyph position from shaping. All fields are in 26.6 fixed-point
units (1/64 px). Fields:

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
    HbFeature

An OpenType feature to apply while shaping: a 4-byte `tag`, a `value`
(0 disables, 1 enables, higher values select an alternate), and the
half-open buffer range `[start, stop)` it applies to.
"""
struct HbFeature
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
    HbFeature(_name_to_tag(name), UInt32(value),
              HB_FEATURE_GLOBAL_START, HB_FEATURE_GLOBAL_END)

"""
    shape!(font::HbFont, buf::HbBuffer; features=nothing)

Shape the text in `buf` using `font`. Returns a `ShapeResult` with
glyph infos and positions.
"""
function shape!(font::HbFont, buf::HbBuffer;
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

# Pack a feature name into an `hb_tag_t`. Tags are exactly four bytes;
# shorter names are padded with spaces, longer ones are truncated, which
# is what `hb_tag_from_string` does.
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

"""
    shape(font::HbFont, text::AbstractString; features=nothing) -> ShapeResult

One-shot convenience: create a buffer, add text, guess segment
properties, shape, and return the result.

```julia
result = shape(font, "Hello")
result = shape(font, "AVATAR"; features = [("kern", 0)])
```
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
    get_nominal_glyph(font::HbFont, unicode::UInt32) -> UInt32

Return the glyph ID for a Unicode codepoint, or 0 if the font does
not contain it.
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

export HbFont, HbBuffer,
       GlyphInfo, GlyphPosition, ShapeResult,
       clear!, add_text!, guess_segment_properties!,
       shape!, shape, glyph_ids, clusters,
       get_nominal_glyph, has_glyph

end # module