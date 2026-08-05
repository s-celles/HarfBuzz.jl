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

@run_package_tests