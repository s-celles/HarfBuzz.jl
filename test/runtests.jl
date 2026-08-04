using TestItemRunner

# Cross-platform font path resolution. Each platform has a different
# monospace font and a different CJK font. Tests skip (return) if no
# suitable font is found, so they run on macOS/Linux/Windows CI without
# hard-coding platform-specific paths.

function _find_mono_font()
    candidates = [
        # macOS
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
        "/System/Library/Fonts/Courier.ttc",
        # Linux
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
        # Windows
        "C:\\Windows\\Fonts\\consola.ttf",
        "C:\\Windows\\Fonts\\cour.ttf",
        "C:\\Windows\\Fonts\\lucon.ttf",
    ]
    for p in candidates
        isfile(p) && return p
    end
    return nothing
end

function _find_cjk_font()
    candidates = [
        # macOS
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/AppleSDGothicNeo.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        # Linux
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/droid/DroidSansFallback.ttf",
        # Windows
        "C:\\Windows\\Fonts\\msyh.ttc",
        "C:\\Windows\\Fonts\\simsun.ttc",
        "C:\\Windows\\Fonts\\malgun.ttf",
    ]
    for p in candidates
        isfile(p) && return p
    end
    return nothing
end

@testitem "HbFont creation" begin
    import HarfBuzz
    mono = Main._find_mono_font()
    mono === nothing && return  # skip if no font found
    font = HarfBuzz.HbFont(mono, 18)
    @test font.ptr != C_NULL
end

@testitem "has_glyph for ASCII" begin
    import HarfBuzz
    mono = Main._find_mono_font()
    mono === nothing && return
    font = HarfBuzz.HbFont(mono, 18)
    # ASCII — every monospace font has these
    @test HarfBuzz.has_glyph(font, UInt32('A'))
    @test HarfBuzz.has_glyph(font, UInt32('M'))
    @test HarfBuzz.has_glyph(font, UInt32('|'))
end

@testitem "has_glyph: monospace font lacks CJK" begin
    import HarfBuzz
    mono = Main._find_mono_font()
    mono === nothing && return
    font = HarfBuzz.HbFont(mono, 18)
    # CJK — most monospace fonts do NOT have these
    @test !HarfBuzz.has_glyph(font, UInt32(0x6f22))  # 漢
end

@testitem "shape basic ASCII" begin
    import HarfBuzz
    mono = Main._find_mono_font()
    mono === nothing && return
    font = HarfBuzz.HbFont(mono, 18)

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
    cjk = Main._find_cjk_font()
    cjk === nothing && return
    font = HarfBuzz.HbFont(cjk, 18)

    result = HarfBuzz.shape(font, "🇫🇷")
    @test length(result.infos) >= 1
    @test minimum(HarfBuzz.clusters(result)) == 0
end

@testitem "shape CJK" begin
    import HarfBuzz
    cjk = Main._find_cjk_font()
    cjk === nothing && return
    font = HarfBuzz.HbFont(cjk, 18)

    result = HarfBuzz.shape(font, "漢字")
    @test length(result.infos) == 2
    for g in result.infos
        @test g.glyph_id != 0
    end
    @test HarfBuzz.clusters(result) == [0, 3]
end

@run_package_tests