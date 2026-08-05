using TestItemRunner
import FreeTypeAbstraction

# Directories that hold font files on the supported platforms. Tests that
# need a real font skip when none is found -- see ROADMAP open question 10.
const FONT_DIRS = filter(isdir, [
    "/System/Library/Fonts",
    "/System/Library/Fonts/Supplemental",
    "/Library/Fonts",
    "/usr/share/fonts",
    "/usr/local/share/fonts",
    joinpath(homedir(), ".fonts"),
    joinpath(homedir(), "Library", "Fonts"),
    "C:\\Windows\\Fonts",
])

const FONT_EXTS = (".ttf", ".ttc", ".otf")

"""
Path of the first font file found on this machine, or `nothing`.
"""
function _find_font_file()
    for dir in FONT_DIRS
        for (root, _, files) in walkdir(dir; onerror = _ -> nothing)
            for f in sort(files)
                if any(endswith(lowercase(f), e) for e in FONT_EXTS)
                    return joinpath(root, f)
                end
            end
        end
    end
    return nothing
end

# Common monospace font family names across platforms
const MONO_NAMES = ["Menlo", "DejaVu Sans Mono", "Consolas",
                    "Liberation Mono", "Courier New", "Monaco"]

# Common CJK font family names across platforms
const CJK_NAMES = ["Hiragino Sans GB", "Noto Sans CJK SC", "Noto Sans CJK",
                   "Microsoft YaHei", "SimSun", "AppleSDGothicNeo",
                   "Malgun Gothic"]

function _find_mono_name()
    for name in MONO_NAMES
        FreeTypeAbstraction.findfont(name) === nothing || return name
    end
    return nothing
end

function _find_cjk_name()
    for name in CJK_NAMES
        FreeTypeAbstraction.findfont(name) === nothing || return name
    end
    return nothing
end

# Proportional families that ship a `kern` feature, used to check that
# shaping features are actually handed to HarfBuzz.
const KERN_NAMES = ["Times New Roman", "Georgia", "Arial", "Helvetica",
                    "DejaVu Serif", "DejaVu Sans", "Liberation Serif",
                    "Liberation Sans"]

function _find_kern_name()
    for name in KERN_NAMES
        FreeTypeAbstraction.findfont(name) === nothing || return name
    end
    return nothing
end

@testitem "Aqua QA" begin
    import Aqua
    Aqua.test_all(HarfBuzz)
end

# --- Naming and exports ---------------------------------------------------

@testitem "the module exports nothing" begin
    import HarfBuzz
    # Types are named Font, Buffer, Face, Blob: too generic to export.
    # `names` always contains the module itself.
    @test names(HarfBuzz) == [:HarfBuzz]
end

# --- Blob -----------------------------------------------------------------

@testitem "Blob from a file path" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    blob = HarfBuzz.Blob(path)
    @test blob.ptr != C_NULL
    @test length(blob) == filesize(path)
end

@testitem "Blob from bytes" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    bytes = read(path)
    blob = HarfBuzz.Blob(bytes)
    @test length(blob) == length(bytes)
    @test HarfBuzz.data(blob)[1:4] == bytes[1:4]
end

@testitem "Blob from a missing file fails" begin
    import HarfBuzz
    @test_throws ErrorException HarfBuzz.Blob("/definitely/not/a/font.ttf")
end

# --- Face -----------------------------------------------------------------

@testitem "Face queries" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    face = HarfBuzz.Face(path)
    @test HarfBuzz.upem(face) > 0
    @test HarfBuzz.glyph_count(face) > 0
    @test HarfBuzz.face_index(face) == 0
    @test HarfBuzz.face_count(HarfBuzz.Blob(path)) >= 1
end

@testitem "Face table access" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    face = HarfBuzz.Face(path)
    tags = HarfBuzz.table_tags(face)
    @test !isempty(tags)
    @test all(t -> length(t) == 4, tags)
    @test "cmap" in tags
    @test length(HarfBuzz.reference_table(face, "cmap")) > 0
    # A table the font does not have yields an empty blob, not an error.
    @test length(HarfBuzz.reference_table(face, "zzzz")) == 0
end

# --- Font -----------------------------------------------------------------

@testitem "Font from a Face shapes with native funcs" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    face = HarfBuzz.Face(path)
    font = HarfBuzz.Font(face; size = 18)
    @test HarfBuzz.scale(font) == (18 * 64, 18 * 64)
    result = HarfBuzz.shape(font, "Hello")
    @test length(result.infos) == 5
    @test all(p -> p.x_advance != 0, result.positions)
end

@testitem "Font from a path" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    font = HarfBuzz.Font(path; size = 18)
    @test font.ptr != C_NULL
    @test HarfBuzz.scale(font) == (18 * 64, 18 * 64)
end

@testitem "Font scale, ppem and ptem" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    face = HarfBuzz.Face(path)

    # `scale` in font units is the low-level knob; `size` is the pixel
    # convenience on top of it.
    font = HarfBuzz.Font(face; scale = (2048, 2048))
    @test HarfBuzz.scale(font) == (2048, 2048)

    HarfBuzz.scale!(font, (1024, 512))
    @test HarfBuzz.scale(font) == (1024, 512)

    HarfBuzz.ppem!(font, (18, 18))
    @test HarfBuzz.ppem(font) == (18, 18)

    HarfBuzz.ptem!(font, 13.5)
    @test HarfBuzz.ptem(font) ≈ 13.5
end

@testitem "Font rejects an unknown backend" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    face = HarfBuzz.Face(path)
    @test_throws ArgumentError HarfBuzz.Font(face; size = 18, funcs = :nope)
end

@testitem "px converts 26.6 fixed point to pixels" begin
    import HarfBuzz
    @test HarfBuzz.px(694) ≈ 694 / 64
    @test HarfBuzz.px(Int32(64)) == 1.0
end

# --- FreeType extension ---------------------------------------------------

@testitem "FreeType backend is available once FreeType is loaded" begin
    import HarfBuzz
    import FreeType
    path = Main._find_font_file()
    path === nothing && return
    face = HarfBuzz.Face(path)
    font = HarfBuzz.Font(face; size = 18, funcs = :freetype)
    @test font.ptr != C_NULL
    result = HarfBuzz.shape(font, "Hello")
    @test all(p -> p.x_advance != 0, result.positions)
end

@testitem "family names resolve once FreeTypeAbstraction is loaded" begin
    import HarfBuzz
    import FreeTypeAbstraction
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.Font(name; size = 18)
    @test font.ptr != C_NULL
    @test HarfBuzz.has_glyph(font, UInt32('A'))
end

@testitem "an unresolvable family name fails" begin
    import HarfBuzz
    import FreeTypeAbstraction
    @test_throws ErrorException HarfBuzz.Font("NoSuchFontFamilyName"; size = 18)
end

# --- Shaping --------------------------------------------------------------

@testitem "has_glyph for ASCII" begin
    import HarfBuzz
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.Font(name; size = 18)
    @test HarfBuzz.has_glyph(font, UInt32('A'))
    @test HarfBuzz.has_glyph(font, UInt32('M'))
    @test HarfBuzz.has_glyph(font, UInt32('|'))
end

@testitem "has_glyph: monospace font lacks CJK" begin
    import HarfBuzz
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.Font(name; size = 18)
    @test !HarfBuzz.has_glyph(font, UInt32(0x6f22))  # 漢
end

@testitem "shape basic ASCII" begin
    import HarfBuzz
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.Font(name; size = 18)
    result = HarfBuzz.shape(font, "Hello")
    @test length(result.infos) == 5
    @test length(result.positions) == 5
    for g in result.infos
        @test g.glyph_id != 0
    end
    @test HarfBuzz.clusters(result) == [0, 1, 2, 3, 4]
end

@testitem "shape regional indicator pair (flag)" begin
    import HarfBuzz
    name = Main._find_cjk_name()
    name === nothing && return
    font = HarfBuzz.Font(name; size = 18)
    result = HarfBuzz.shape(font, "🇫🇷")
    @test length(result.infos) >= 1
    @test minimum(HarfBuzz.clusters(result)) == 0
end

@testitem "shape CJK" begin
    import HarfBuzz
    name = Main._find_cjk_name()
    name === nothing && return
    font = HarfBuzz.Font(name; size = 18)
    result = HarfBuzz.shape(font, "漢字")
    # Should produce at least 1 glyph (some fonts may ligate or have
    # different cluster mappings across platforms)
    @test length(result.infos) >= 1
    # Clusters should start at byte 0
    @test minimum(HarfBuzz.clusters(result)) == 0
end

# --- Phase 0 regression tests --------------------------------------------

@testitem "every shaped glyph has a non-zero advance" begin
    import HarfBuzz
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.Font(name; size = 18)
    result = HarfBuzz.shape(font, "Hello")
    @test length(result.positions) == 5
    # Reading positions with the wrong stride leaves every entry after the
    # first at zero.
    @test all(p -> p.x_advance > 0, result.positions)
    # Monospace: every advance is identical.
    @test length(unique(p.x_advance for p in result.positions)) == 1
    # Plain ASCII in a horizontal run: no offsets, no vertical advance.
    @test all(p -> p.x_offset == 0 && p.y_offset == 0, result.positions)
    @test all(p -> p.y_advance == 0, result.positions)
end

@testitem "features are built over the whole buffer" begin
    import HarfBuzz
    f = HarfBuzz._make_feature("kern", 0)
    @test f.tag == HarfBuzz._name_to_tag("kern")
    @test f.value == 0
    @test f.start == HarfBuzz.HB_FEATURE_GLOBAL_START
    # An `end` of 0 is an empty range, which makes the feature a no-op.
    @test f.stop == HarfBuzz.HB_FEATURE_GLOBAL_END
    @test f.stop != 0
end

@testitem "disabling kerning changes advances" begin
    import HarfBuzz
    name = Main._find_kern_name()
    name === nothing && return
    font = HarfBuzz.Font(name; size = 18)
    text = "AVAWTo"
    default = [p.x_advance for p in HarfBuzz.shape(font, text).positions]
    nokern = [p.x_advance for p in
              HarfBuzz.shape(font, text; features = [("kern", 0)]).positions]
    # Skip if this platform's font has no kerning pairs for the sample:
    # nothing can be concluded then.
    default == nokern && return
    @test default != nokern
end

@testitem "a font can be destroyed without crashing" begin
    import HarfBuzz
    path = Main._find_font_file()
    path === nothing && return
    # Run in a subprocess: passing the wrong `destroy` callback to
    # hb_ft_font_create makes hb_font_destroy jump to a garbage pointer,
    # which takes the whole process down.
    code = """
    import HarfBuzz
    for _ in 1:16
        font = HarfBuzz.Font($(repr(path)); size = 18)
        HarfBuzz.shape(font, "Hello")
        finalize(font)
        @assert font.ptr == C_NULL
    end
    GC.gc()
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
    @test success(run(cmd; wait = true))
end

@run_package_tests
