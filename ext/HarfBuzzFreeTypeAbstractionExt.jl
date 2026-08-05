module HarfBuzzFreeTypeAbstractionExt

# Lets `HarfBuzz.Font(family_name; size = ...)` resolve a family name.
# HarfBuzz has no font database of its own, so this needs a font matcher;
# FreeTypeAbstraction provides one. Fonts opened this way are always
# FreeType-backed.

import FreeType
import FreeTypeAbstraction
import HarfBuzz

function resolve(name::AbstractString; size = nothing, scale = nothing)
    ftfont = FreeTypeAbstraction.findfont(String(name))
    ftfont === nothing && throw(ErrorException(
        "font not found: '$name'. Searched paths: " *
        join(FreeTypeAbstraction.fontpaths(), ", ")))

    size_px = HarfBuzz._size_px(size, scale)
    err = FreeType.FT_Set_Char_Size(ftfont, 0, round(Int, size_px * 64), 0, 0)
    err != 0 && throw(ErrorException("FT_Set_Char_Size failed: $err"))

    ptr = ccall((:hb_ft_font_create_referenced, HarfBuzz.libhb),
                Ptr{Cvoid}, (Ptr{Cvoid},), ftfont.ft_ptr)
    ptr == C_NULL && throw(ErrorException("hb_ft_font_create_referenced failed"))

    # Anchor the FTFont: FreeTypeAbstraction owns the FT_Face and frees it
    # when the Julia object is collected.
    font = HarfBuzz.Font(ptr, nothing, ftfont)
    finalizer(HarfBuzz._font_destroy, font)

    if scale !== nothing
        HarfBuzz._apply_scale!(font, size, scale)
        ccall((:hb_ft_font_changed, HarfBuzz.libhb), Cvoid, (Ptr{Cvoid},), ptr)
    end
    return font
end

function __init__()
    HarfBuzz._FAMILY_RESOLVER[] = resolve
    return nothing
end

end # module
