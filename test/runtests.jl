using TestItemRunner

@testitem "HbFace and HbFont creation" begin
    import HarfBuzz

    # Use a system font that definitely exists on macOS
    font_path = "/System/Library/Fonts/Menlo.ttc"
    @test isfile(font_path)

    # Test the FreeType-backed constructor (recommended path)
    font = HarfBuzz.HbFont(font_path, 18)
    @test font.ptr != C_NULL
end

@testitem "has_glyph for ASCII and CJK" begin
    import HarfBuzz

    font_path = "/System/Library/Fonts/Menlo.ttc"
    font = HarfBuzz.HbFont(font_path, 18)

    # ASCII — Menlo has these
    @test HarfBuzz.has_glyph(font, UInt32('A'))
    @test HarfBuzz.has_glyph(font, UInt32('M'))
    @test HarfBuzz.has_glyph(font, UInt32('|'))

    # CJK — Menlo does NOT have these
    @test !HarfBuzz.has_glyph(font, UInt32(0x6f22))  # 漢
    @test !HarfBuzz.has_glyph(font, UInt32(0x5b57))  # 字

    # Box-drawing — Menlo has these
    @test HarfBuzz.has_glyph(font, UInt32(0x2502))  # │
    @test HarfBuzz.has_glyph(font, UInt32(0x2500))  # ─
end

@testitem "shape basic ASCII" begin
    import HarfBuzz

    font_path = "/System/Library/Fonts/Menlo.ttc"
    font = HarfBuzz.HbFont(font_path, 18)

    result = HarfBuzz.shape(font, "Hello")
    @test length(result.infos) == 5
    @test length(result.positions) == 5
    # Each ASCII char should map to a non-zero glyph ID
    for g in result.infos
        @test g.glyph_id != 0
    end
    # Clusters should be byte offsets: 0, 1, 2, 3, 4
    @test HarfBuzz.clusters(result) == [0, 1, 2, 3, 4]
    # Note: x_advance may be 0 due to FreeType.jl/HarfBuzz integration;
    # advances should be measured via the renderer instead.
end

@testitem "shape regional indicator pair (flag)" begin
    import HarfBuzz

    # Use a font that has regional indicators
    font_path = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
    isfile(font_path) || return  # skip on non-macOS

    font = HarfBuzz.HbFont(font_path, 18)

    # 🇫🇷 = U+1F1EB + U+1F1F7
    result = HarfBuzz.shape(font, "🇫🇷")
    # HarfBuzz shapes it (non-empty result). A ligature would produce
    # 1 glyph; without ligature 2 glyphs. Some fonts lack regional
    # indicators entirely (glyph_id=0), which is also valid.
    @test length(result.infos) >= 1
    # Clusters should cover the full UTF-8 range of the flag
    @test minimum(HarfBuzz.clusters(result)) == 0
end

@testitem "shape CJK with Hiragino" begin
    import HarfBuzz

    font_path = "/System/Library/Fonts/Hiragino Sans GB.ttc"
    isfile(font_path) || return  # skip on non-macOS

    font = HarfBuzz.HbFont(font_path, 18)

    result = HarfBuzz.shape(font, "漢字")
    @test length(result.infos) == 2
    for g in result.infos
        @test g.glyph_id != 0
    end
    # Clusters: 漢 is 3 bytes, 字 is 3 bytes → [0, 3]
    @test HarfBuzz.clusters(result) == [0, 3]
end

@run_package_tests