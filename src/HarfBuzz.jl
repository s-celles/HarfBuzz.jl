module HarfBuzz

using HarfBuzz_jll
import FreeType
import FreeTypeAbstraction

const libhb = HarfBuzz_jll.libharfbuzz_path

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
    # Leak intentionally: destroying hb_font_t that wraps a FT_Face
    # segfaults on macOS ARM64 because FreeType.jl's struct layout
    # does not match the JLL's expectations. The leak is bounded (one
    # font per HbFont creation) and acceptable for a shaping library
    # used at startup time.
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
        ft_library = Ref{Ptr{FreeType.FT_LibraryRec_}}()
        err = FreeType.FT_Init_FreeType(ft_library)
        err != 0 && throw(ErrorException("FT_Init_FreeType failed: $err"))

        # FT_New_Face writes a `FT_Face` (== Ptr{__JL_FT_FaceRec_})
        # into the ref; the HbFont.ft_face field (Ptr{FT_FaceRec_})
        # accepts it via the usual pointer reinterpretation.
        face_ref = Ref{FreeType.FT_Face}()
        err = FreeType.FT_New_Face(ft_library[], String(name),
                                   Clong(index), face_ref)
        err != 0 && throw(ErrorException(
            "FT_New_Face failed for $name: $err"))
        ft_face = face_ref[]

        char_size = Int(size) * 64
        err = FreeType.FT_Set_Char_Size(ft_face, 0, char_size, 0, 0)
        err != 0 && throw(ErrorException("FT_Set_Char_Size failed: $err"))

        ptr = ccall((:hb_ft_font_create, libhb),
                    Ptr{Cvoid}, (Ptr{Cvoid},), ft_face)
        ptr == C_NULL && throw(ErrorException("hb_ft_font_create failed"))

        font = HbFont(ptr, ft_face, ft_library[], nothing)
        finalizer(_hb_font_destroy, font)
        return font
    else
        # --- Family branch: resolve via FreeTypeAbstraction -----------
        ftfont = FreeTypeAbstraction.findfont(String(name))
        ftfont === nothing && throw(ErrorException(
            "font not found: '$name'. Searched paths: " *
            join(FreeTypeAbstraction.fontpaths(), ", ")))
        char_size = Int(size) * 64
        FreeType.FT_Set_Char_Size(ftfont, 0, char_size, 0, 0)
        ptr = ccall((:hb_ft_font_create, libhb),
                    Ptr{Cvoid}, (Ptr{Cvoid},), ftfont.ft_ptr)
        ptr == C_NULL && throw(ErrorException("hb_ft_font_create failed"))
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

struct GlyphInfo
    glyph_id::UInt32
    cluster::UInt32
end

struct GlyphPosition
    x_advance::Int32
    y_advance::Int32
    x_offset::Int32
    y_offset::Int32
end

struct ShapeResult
    infos::Vector{GlyphInfo}
    positions::Vector{GlyphPosition}
end

const _HB_GLYPH_INFO_SIZE = 20
const _HB_GLYPH_POS_SIZE = 24

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
        feat_arr = Vector{NTuple{4,UInt32}}(undef, nfeat)
        for (i, (name, val)) in enumerate(features)
            tag = _name_to_tag(name)
            feat_arr[i] = (tag, UInt32(val), UInt32(0), UInt32(0))
        end
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

    infos = Vector{GlyphInfo}(undef, n)
    for i in 1:n
        base = info_ptr + (i - 1) * _HB_GLYPH_INFO_SIZE
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

"""
    shape(font::HbFont, text::AbstractString; features=nothing) -> ShapeResult

One-shot convenience: create a buffer, add text, guess segment
properties, shape, and return the result.

Note: glyph advances may be zero due to a FreeType.jl/HarfBuzz
integration issue. Use `glyph_ids` and `clusters` for text shaping
logic, and measure advances via the renderer (e.g. ImGui's
`CalcTextSize` or a fixed cell width for monospace fonts).
"""
function shape(font::HbFont, text::AbstractString;
               features::Union{Nothing,Vector{Tuple{String,Int}}} = nothing)::ShapeResult
    buf = HbBuffer()
    add_text!(buf, text)
    guess_segment_properties!(buf)
    result = shape!(font, buf; features = features)
    return result
end

glyph_ids(result::ShapeResult) = [g.glyph_id for g in result.infos]
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