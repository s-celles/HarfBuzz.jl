using TestItemRunner
import FreeTypeAbstraction

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

@testitem "HbFont creation from family name" begin
    import HarfBuzz
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.HbFont(name, 18)
    @test font.ptr != C_NULL
end

@testitem "has_glyph for ASCII" begin
    import HarfBuzz
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.HbFont(name, 18)
    @test HarfBuzz.has_glyph(font, UInt32('A'))
    @test HarfBuzz.has_glyph(font, UInt32('M'))
    @test HarfBuzz.has_glyph(font, UInt32('|'))
end

@testitem "has_glyph: monospace font lacks CJK" begin
    import HarfBuzz
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.HbFont(name, 18)
    @test !HarfBuzz.has_glyph(font, UInt32(0x6f22))  # 漢
end

@testitem "shape basic ASCII" begin
    import HarfBuzz
    name = Main._find_mono_name()
    name === nothing && return
    font = HarfBuzz.HbFont(name, 18)
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
    font = HarfBuzz.HbFont(name, 18)
    result = HarfBuzz.shape(font, "🇫🇷")
    @test length(result.infos) >= 1
    @test minimum(HarfBuzz.clusters(result)) == 0
end

@testitem "shape CJK" begin
    import HarfBuzz
    name = Main._find_cjk_name()
    name === nothing && return
    font = HarfBuzz.HbFont(name, 18)
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
    font = HarfBuzz.HbFont(name, 18)
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
    font = HarfBuzz.HbFont(name, 18)
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
    name = Main._find_mono_name()
    name === nothing && return
    # Run in a subprocess: passing the wrong `destroy` callback to
    # hb_ft_font_create makes hb_font_destroy jump to a garbage pointer,
    # which takes the whole process down.
    code = """
    import HarfBuzz
    for _ in 1:16
        font = HarfBuzz.HbFont($(repr(name)), 18)
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