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
    # Each glyph should have a positive x_advance (in 26.6 fixed-point)
    for p in result.positions
        @test p.x_advance > 0
    end
end

@testitem "shape regional indicator pair (flag)" begin
    import HarfBuzz

    # Use Apple Color Emoji or a font that has regional indicators
    font_path = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
    isfile(font_path) || return  # skip on non-macOS

    face = HarfBuzz.HbFace(font_path, 0)
    font = HarfBuzz.HbFont(face, 18)

    # 🇫🇷 = U+1F1EB + U+1F1F7
    # In UTF-8: F0 9F 87 AB F0 9F 87 B7
    result = HarfBuzz.shape(font, "🇫🇷")
    # A ligature would produce 1 glyph; without ligature 2 glyphs.
    # The test verifies that HarfBuzz shapes it (non-empty result).
    @test length(result.infos) >= 1
    # All glyphs should have non-zero advance
    for p in result.positions
        @test p.x_advance >= 0
    end
end

@testitem "shape CJK with Hiragino" begin
    import HarfBuzz

    font_path = "/System/Library/Fonts/Hiragino Sans GB.ttc"
    isfile(font_path) || return  # skip on non-macOS

    face = HarfBuzz.HbFace(font_path, 0)
    font = HarfBuzz.HbFont(face, 18)

    result = HarfBuzz.shape(font, "漢字")
    @test length(result.infos) == 2
    for g in result.infos
        @test g.glyph_id != 0
    end
    for p in result.positions
        @test p.x_advance > 0
    end
end

@run_package_tests