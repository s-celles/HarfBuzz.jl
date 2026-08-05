module HarfBuzzFreeTypeExt

# Adds the `funcs = :freetype` backend: glyph metrics come from FreeType
# rather than from HarfBuzz's own table reader, matching FreeType's
# hinting and rounding.

import FreeType
import HarfBuzz

# One library for the whole extension. Not destroyed: see
# `HarfBuzz._font_destroy` for why teardown is left to the OS.
const FT_LIBRARY = Ref{Ptr{FreeType.FT_LibraryRec_}}(C_NULL)

function __init__()
    lib = Ref{Ptr{FreeType.FT_LibraryRec_}}()
    err = FreeType.FT_Init_FreeType(lib)
    err != 0 && throw(ErrorException("FT_Init_FreeType failed: $err"))
    FT_LIBRARY[] = lib[]
    return nothing
end

"""
    ft_face(face::HarfBuzz.Face, size_px) -> FT_Face

Open an `FT_Face` over the bytes the HarfBuzz face already holds, at
`size_px` pixels. The caller must keep the backing blob alive.
"""
function ft_face(face::HarfBuzz.Face, size_px::Real)
    blob = face._blob
    blob === nothing && throw(ArgumentError(
        "the :freetype backend needs a face created from a Blob"))

    len = Ref{Cuint}(0)
    bytes = ccall((:hb_blob_get_data, HarfBuzz.libhb), Ptr{UInt8},
                  (Ptr{Cvoid}, Ref{Cuint}), blob.ptr, len)
    bytes == C_NULL && throw(ErrorException("the face's blob is empty"))

    ref = Ref{FreeType.FT_Face}()
    err = ccall((:FT_New_Memory_Face, FreeType.libfreetype), Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, Clong, Clong, Ptr{Cvoid}),
                FT_LIBRARY[], bytes, Clong(len[]),
                Clong(HarfBuzz.face_index(face)), ref)
    err != 0 && throw(ErrorException("FT_New_Memory_Face failed: $err"))

    ft = ref[]
    err = FreeType.FT_Set_Char_Size(ft, 0, round(Int, size_px * 64), 0, 0)
    if err != 0
        FreeType.FT_Done_Face(ft)
        throw(ErrorException("FT_Set_Char_Size failed: $err"))
    end
    return ft
end

function HarfBuzz._create_font(::Val{:freetype}, face::HarfBuzz.Face, size, scale)
    ft = ft_face(face, HarfBuzz._size_px(size, scale))

    # `_referenced` takes its own reference on the FT_Face and installs
    # FT_Done_Face as the destroy callback.
    ptr = ccall((:hb_ft_font_create_referenced, HarfBuzz.libhb),
                Ptr{Cvoid}, (Ptr{Cvoid},), ft)
    if ptr == C_NULL
        FreeType.FT_Done_Face(ft)
        throw(ErrorException("hb_ft_font_create_referenced failed"))
    end
    # Drop the reference taken by FT_New_Memory_Face; HarfBuzz holds the
    # remaining one. The blob stays anchored: FreeType reads from it.
    FreeType.FT_Done_Face(ft)

    font = HarfBuzz.Font(ptr, face, face._blob)
    finalizer(HarfBuzz._font_destroy, font)

    if scale !== nothing
        HarfBuzz._apply_scale!(font, size, scale)
        # hb-ft caches multipliers derived from the scale it set from the
        # FT_Face; tell it they are stale.
        ccall((:hb_ft_font_changed, HarfBuzz.libhb), Cvoid, (Ptr{Cvoid},), ptr)
    end
    return font
end

end # module
