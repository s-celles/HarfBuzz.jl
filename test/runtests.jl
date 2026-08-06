using TestItemRunner
import HarfBuzz   # top level: used to probe system fonts for coverage

# Every assertion about shaping runs against a font vendored with the
# suite, so results do not depend on what a machine happens to have
# installed. See test/fonts/README.md for its provenance and for what it
# is known to exercise.
const TEST_FONT = joinpath(@__DIR__, "fonts", "NotoSans-subset.ttf")
const TEST_FONT_VAR = joinpath(@__DIR__, "fonts", "NotoSans-variable-subset.ttf")

# System fonts are still used, but only for coverage these cannot give
# (CJK) or to check that arbitrary real-world files load. Those tests use
# `@test_skip` inside an `if/else`, so a machine without the font reports a
# Broken count instead of passing silently.
#
# Note: `return` does NOT exit a @testitem body -- TestItemRunner keeps
# evaluating what follows -- so the guard has to be an `else` branch.
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

const _CJK_FONT = Ref{Any}(missing)

"""
Path of a system font that actually covers U+6F22 (漢).

Coverage is asked of HarfBuzz rather than guessed from the file name,
which is both more honest and platform-independent: `fonts-noto-cjk` on
Linux, Hiragino on macOS and MS Gothic on Windows all answer the same
question. The result is cached; `nothing` means this machine has none.
"""
function _find_cjk_font()
    _CJK_FONT[] === missing || return _CJK_FONT[]
    found = nothing
    for dir in FONT_DIRS, (root, _, files) in walkdir(dir; onerror = _ -> nothing)
        for f in sort(files)
            any(endswith(lowercase(f), e) for e in FONT_EXTS) || continue
            path = joinpath(root, f)
            try
                font = HarfBuzz.Font(path; size = 18)
                if HarfBuzz.has_glyph(font, UInt32(0x6f22))
                    found = path
                    break
                end
            catch
                # Unreadable or exotic file: not our problem here.
            end
        end
        found === nothing || break
    end
    _CJK_FONT[] = found
    return found
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
    path = Main.TEST_FONT
    blob = HarfBuzz.Blob(path)
    @test blob.ptr != C_NULL
    @test length(blob) == filesize(path)
end

@testitem "Blob from bytes" begin
    import HarfBuzz
    path = Main.TEST_FONT
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
    path = Main.TEST_FONT
    face = HarfBuzz.Face(path)
    @test HarfBuzz.upem(face) > 0
    @test HarfBuzz.glyph_count(face) > 0
    @test HarfBuzz.face_index(face) == 0
    @test HarfBuzz.face_count(HarfBuzz.Blob(path)) >= 1
end

@testitem "Face table access" begin
    import HarfBuzz
    path = Main.TEST_FONT
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
    path = Main.TEST_FONT
    face = HarfBuzz.Face(path)
    font = HarfBuzz.Font(face; size = 18)
    @test HarfBuzz.scale(font) == (18 * 64, 18 * 64)
    result = HarfBuzz.shape(font, "Hello")
    @test length(result.infos) == 5
    @test all(p -> p.x_advance != 0, result.positions)
end

@testitem "Font from a path" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    @test font.ptr != C_NULL
    @test HarfBuzz.scale(font) == (18 * 64, 18 * 64)
end

@testitem "Font scale, ppem and ptem" begin
    import HarfBuzz
    path = Main.TEST_FONT
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
    path = Main.TEST_FONT
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
    path = Main.TEST_FONT
    face = HarfBuzz.Face(path)
    font = HarfBuzz.Font(face; size = 18, funcs = :freetype)
    @test font.ptr != C_NULL
    result = HarfBuzz.shape(font, "Hello")
    @test all(p -> p.x_advance != 0, result.positions)
end

@testitem "a Font name that is not a file is rejected" begin
    import HarfBuzz
    # The package matches no font names: HarfBuzz has no font database and
    # neither does this wrapper. The error must say so.
    err = try
        HarfBuzz.Font("DejaVu Sans"; size = 18)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("not a file", sprint(showerror, err))
end

@testitem "an arbitrary system font loads and shapes" begin
    import HarfBuzz
    # Smoke test against a real-world file rather than the vendored subset:
    # catches anything that only works on a font we control.
    path = Main._find_font_file()
    if path === nothing
        @test_skip "no system font found on this machine"
    else
        face = HarfBuzz.Face(path)
        @test HarfBuzz.upem(face) > 0
        font = HarfBuzz.Font(face; size = 18)
        @test HarfBuzz.shape(font, "Hello") isa HarfBuzz.ShapeResult
    end
end

# --- Shaping --------------------------------------------------------------

@testitem "has_glyph for ASCII" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    @test HarfBuzz.has_glyph(font, UInt32('A'))
    @test HarfBuzz.has_glyph(font, UInt32('M'))
    @test HarfBuzz.has_glyph(font, UInt32('|'))
end

@testitem "has_glyph: the test font has no CJK coverage" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    @test !HarfBuzz.has_glyph(font, UInt32(0x6f22))  # 漢
end

@testitem "shape basic ASCII" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
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
    path = Main._find_cjk_font()
    if path === nothing
        @test_skip "needs a system font with CJK coverage"
    else
        font = HarfBuzz.Font(path; size = 18)
        result = HarfBuzz.shape(font, "🇫🇷")
        @test length(result.infos) >= 1
        @test minimum(HarfBuzz.clusters(result)) == 0
    end
end

@testitem "shape CJK" begin
    import HarfBuzz
    path = Main._find_cjk_font()
    if path === nothing
        @test_skip "needs a system font with CJK coverage"
    else
        font = HarfBuzz.Font(path; size = 18)
        result = HarfBuzz.shape(font, "漢字")
        # Some fonts ligate, or map clusters differently, so only the
        # floor is asserted.
        @test length(result.infos) >= 1
        @test minimum(HarfBuzz.clusters(result)) == 0
    end
end

# --- Library and tag helpers ---------------------------------------------

@testitem "library version" begin
    import HarfBuzz
    v = HarfBuzz.version()
    @test v isa VersionNumber
    @test v >= v"8"
    @test startswith(HarfBuzz.version_string(), string(v.major))
end

@testitem "tags round-trip" begin
    import HarfBuzz
    @test HarfBuzz.tag_string(HarfBuzz.tag("kern")) == "kern"
    @test HarfBuzz.tag_string(HarfBuzz.tag("cv01")) == "cv01"
    # Short names are padded to four bytes, long ones truncated.
    @test HarfBuzz.tag_string(HarfBuzz.tag("cv")) == "cv  "
    @test HarfBuzz.tag_string(HarfBuzz.tag("toolong")) == "tool"
end

@testitem "available shapers" begin
    import HarfBuzz
    shapers = HarfBuzz.shapers()
    @test !isempty(shapers)
    @test "ot" in shapers
    @test all(s -> s isa String, shapers)
end

# --- Buffer properties ----------------------------------------------------

@testitem "buffer direction, script and language" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "abc")

    HarfBuzz.direction!(buf, :rtl)
    @test HarfBuzz.direction(buf) == :rtl
    HarfBuzz.direction!(buf, :ltr)
    @test HarfBuzz.direction(buf) == :ltr

    HarfBuzz.script!(buf, :Arab)
    @test HarfBuzz.script(buf) == :Arab

    HarfBuzz.language!(buf, "fr")
    @test HarfBuzz.language(buf) == "fr"
end

@testitem "guess_segment_properties fills the properties" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "مرحبا")
    HarfBuzz.guess_segment_properties!(buf)
    @test HarfBuzz.direction(buf) == :rtl
    @test HarfBuzz.script(buf) == :Arab

    props = HarfBuzz.segment_properties(buf)
    @test props.direction == :rtl
    @test props.script == :Arab
end

@testitem "segment_properties! sets all three at once" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "abc")
    HarfBuzz.segment_properties!(buf,
        (direction = :ltr, script = :Latn, language = "en"))
    @test HarfBuzz.segment_properties(buf) ==
          (direction = :ltr, script = :Latn, language = "en")
end

@testitem "buffer flags" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    @test HarfBuzz.flags(buf) == Symbol[]
    HarfBuzz.flags!(buf, [:bot, :eot])
    @test sort(HarfBuzz.flags(buf)) == [:bot, :eot]
    HarfBuzz.flags!(buf, Symbol[])
    @test HarfBuzz.flags(buf) == Symbol[]
    @test_throws ArgumentError HarfBuzz.flags!(buf, [:not_a_flag])
end

@testitem "buffer cluster level and content type" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    @test HarfBuzz.cluster_level(buf) == :monotone_graphemes
    HarfBuzz.cluster_level!(buf, :characters)
    @test HarfBuzz.cluster_level(buf) == :characters
    @test_throws ArgumentError HarfBuzz.cluster_level!(buf, :nope)

    @test HarfBuzz.content_type(buf) == :invalid
    HarfBuzz.add_text!(buf, "abc")
    @test HarfBuzz.content_type(buf) == :unicode
end

@testitem "buffer replacement and special glyphs" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    HarfBuzz.replacement_codepoint!(buf, UInt32('?'))
    @test HarfBuzz.replacement_codepoint(buf) == UInt32('?')
    HarfBuzz.invisible_glyph!(buf, UInt32(3))
    @test HarfBuzz.invisible_glyph(buf) == 3
    HarfBuzz.not_found_glyph!(buf, UInt32(1))
    @test HarfBuzz.not_found_glyph(buf) == 1
end

# --- Buffer contents ------------------------------------------------------

@testitem "buffer length, reset and clear" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    @test length(buf) == 0
    @test isempty(buf)
    HarfBuzz.add_text!(buf, "hello")
    @test length(buf) == 5
    @test !isempty(buf)

    HarfBuzz.clear!(buf)
    @test length(buf) == 0

    HarfBuzz.add_text!(buf, "hi")
    HarfBuzz.direction!(buf, :rtl)
    HarfBuzz.reset!(buf)
    # reset also drops the properties, unlike clear!
    @test length(buf) == 0
    @test HarfBuzz.direction(buf) == :invalid
end

@testitem "add_text! with an item range" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    # The whole string is context; only bytes 3:5 become items.
    HarfBuzz.add_text!(buf, "abcdefgh"; item_offset = 2, item_length = 3)
    @test length(buf) == 3
    @test HarfBuzz.codepoints(buf) == UInt32.(collect("cde"))
end

@testitem "add_codepoints!" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_codepoints!(buf, UInt32[0x41, 0x42, 0x43])
    @test length(buf) == 3
    @test HarfBuzz.codepoints(buf) == UInt32[0x41, 0x42, 0x43]
end

@testitem "append! joins two buffers" begin
    import HarfBuzz
    a = HarfBuzz.Buffer(); HarfBuzz.add_text!(a, "ab")
    b = HarfBuzz.Buffer(); HarfBuzz.add_text!(b, "cd")
    append!(a, b)
    @test length(a) == 4
    @test HarfBuzz.codepoints(a) == UInt32.(collect("abcd"))
end

@testitem "reverse! and reverse_clusters!" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "abc")
    HarfBuzz.reverse!(buf)
    @test HarfBuzz.codepoints(buf) == UInt32.(collect("cba"))
    HarfBuzz.reverse_clusters!(buf)
    @test HarfBuzz.codepoints(buf) == UInt32.(collect("abc"))
end

@testitem "pre_allocate! reports success" begin
    import HarfBuzz
    buf = HarfBuzz.Buffer()
    @test HarfBuzz.pre_allocate!(buf, 128)
    @test HarfBuzz.allocation_successful(buf)
end

# --- Glyph flags ----------------------------------------------------------

@testitem "glyph flags are decoded" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    # "Hello" has no kerning pair and no ligature in the test font, so
    # every position is safe to break.
    plain = HarfBuzz.shape(font, "Hello")
    @test all(i -> !HarfBuzz.unsafe_to_break(i), plain.infos)
    @test all(i -> i.flags & ~HarfBuzz.HB_GLYPH_FLAG_DEFINED == 0, plain.infos)

    # "AVA" is two kerning pairs: breaking before either V or the second A
    # would change the result. Deterministic with the vendored font.
    kerned = HarfBuzz.shape(font, "AVA")
    @test length(kerned.infos) == 3
    @test !HarfBuzz.unsafe_to_break(kerned.infos[1])
    @test HarfBuzz.unsafe_to_break(kerned.infos[2])
    @test HarfBuzz.unsafe_to_break(kerned.infos[3])
end

@testitem "ligatures merge clusters" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)

    # The test font ligates "ffi": six characters come back as four glyphs,
    # and the ligature's cluster spans the three it replaced.
    with = HarfBuzz.shape(font, "office")
    without = HarfBuzz.shape(font, "office"; features = ["liga=0"])
    @test length(without.infos) == 6
    @test length(with.infos) == 4
    @test HarfBuzz.clusters(with) == [0, 1, 4, 5]
    @test HarfBuzz.glyph_ids(with) != HarfBuzz.glyph_ids(without)
end

@testitem "glyph flag predicates" begin
    import HarfBuzz
    none = HarfBuzz.GlyphInfo(UInt32(1), UInt32(0), UInt32(0))
    brk = HarfBuzz.GlyphInfo(UInt32(1), UInt32(0),
                             HarfBuzz.HB_GLYPH_FLAG_UNSAFE_TO_BREAK)
    cat = HarfBuzz.GlyphInfo(UInt32(1), UInt32(0),
                             HarfBuzz.HB_GLYPH_FLAG_UNSAFE_TO_CONCAT)
    tat = HarfBuzz.GlyphInfo(UInt32(1), UInt32(0),
                             HarfBuzz.HB_GLYPH_FLAG_SAFE_TO_INSERT_TATWEEL)

    @test !HarfBuzz.unsafe_to_break(none)
    @test HarfBuzz.unsafe_to_break(brk)
    @test !HarfBuzz.unsafe_to_concat(brk)
    @test HarfBuzz.unsafe_to_concat(cat)
    @test !HarfBuzz.unsafe_to_break(cat)
    @test HarfBuzz.safe_to_insert_tatweel(tat)
end

@testitem "produce_unsafe_to_concat is accepted by shaping" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "office")
    HarfBuzz.guess_segment_properties!(buf)
    HarfBuzz.flags!(buf, [:produce_unsafe_to_concat])
    result = HarfBuzz.shape!(font, buf)
    @test length(result.infos) >= 1
    # Whatever the font does, only the three defined bits may be set.
    @test all(i -> i.flags & ~HarfBuzz.HB_GLYPH_FLAG_DEFINED == 0, result.infos)
end

# --- Serialization --------------------------------------------------------

@testitem "serialize to text" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "Hi")
    HarfBuzz.guess_segment_properties!(buf)
    HarfBuzz.shape!(font, buf)

    text = HarfBuzz.serialize(buf; font = font)
    @test text isa String
    @test !isempty(text)
    @test count('|', text) == 1     # two glyphs, one separator
end

@testitem "serialize to JSON" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "Hi")
    HarfBuzz.guess_segment_properties!(buf)
    HarfBuzz.shape!(font, buf)

    json = HarfBuzz.serialize(buf; font = font, format = :json)
    @test startswith(json, "[")
    @test endswith(json, "]")
    @test occursin("\"cl\"", json)
end

@testitem "serialize round-trips through deserialize" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "Hello")
    HarfBuzz.guess_segment_properties!(buf)
    HarfBuzz.shape!(font, buf)
    text = HarfBuzz.serialize(buf; font = font)

    other = HarfBuzz.Buffer()
    HarfBuzz.deserialize!(other, text; font = font)
    @test HarfBuzz.glyph_infos(other) == HarfBuzz.glyph_infos(buf)
end

@testitem "serialize honours flags" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "Hi")
    HarfBuzz.guess_segment_properties!(buf)
    HarfBuzz.shape!(font, buf)

    with = HarfBuzz.serialize(buf; font = font)
    without = HarfBuzz.serialize(buf; font = font,
                                 flags = [:no_clusters, :no_positions])
    @test with != without
    @test !occursin("=", without)
end

# --- Buffer comparison ----------------------------------------------------

@testitem "diff reports equality and mismatches" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)

    a = HarfBuzz.Buffer(); HarfBuzz.add_text!(a, "Hi")
    HarfBuzz.guess_segment_properties!(a); HarfBuzz.shape!(font, a)
    b = HarfBuzz.Buffer(); HarfBuzz.add_text!(b, "Hi")
    HarfBuzz.guess_segment_properties!(b); HarfBuzz.shape!(font, b)
    @test HarfBuzz.diff(a, b) == Symbol[]

    c = HarfBuzz.Buffer(); HarfBuzz.add_text!(c, "Ho")
    HarfBuzz.guess_segment_properties!(c); HarfBuzz.shape!(font, c)
    @test :codepoint_mismatch in HarfBuzz.diff(a, c)
end

# --- Shapers and features -------------------------------------------------

@testitem "shape! accepts a shaper list" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "Hello")
    HarfBuzz.guess_segment_properties!(buf)
    result = HarfBuzz.shape!(font, buf; shapers = ["ot"])
    @test length(result.infos) == 5

    buf2 = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf2, "Hello")
    HarfBuzz.guess_segment_properties!(buf2)
    @test_throws ErrorException HarfBuzz.shape!(font, buf2;
                                                shapers = ["no-such-shaper"])
end

@testitem "features parse from HarfBuzz string syntax" begin
    import HarfBuzz
    f = HarfBuzz.Feature("kern=0")
    @test f.tag == HarfBuzz.tag("kern")
    @test f.value == 0
    @test f.start == HarfBuzz.HB_FEATURE_GLOBAL_START
    @test f.stop == HarfBuzz.HB_FEATURE_GLOBAL_END

    @test HarfBuzz.Feature("+liga").value == 1
    @test HarfBuzz.Feature("-liga").value == 0

    ranged = HarfBuzz.Feature("aalt[3:5]=2")
    @test ranged.value == 2
    @test ranged.start == 3
    @test ranged.stop == 5

    @test occursin("kern", string(HarfBuzz.Feature("kern=0")))
    @test_throws ArgumentError HarfBuzz.Feature("!!not a feature!!")
end

@testitem "the three accepted feature forms agree" begin
    import HarfBuzz
    # A string, a pair and a Feature must build the same thing.
    from_str = HarfBuzz._as_feature("kern=0")
    from_pair = HarfBuzz._as_feature("kern" => 0)
    from_obj = HarfBuzz._as_feature(HarfBuzz.Feature("kern=0"))
    @test from_str == from_pair == from_obj

    # Only the string form carries a range.
    ranged = HarfBuzz._as_feature("kern[0:3]=0")
    @test ranged.start == 0 && ranged.stop == 3
    @test from_pair.stop == HarfBuzz.HB_FEATURE_GLOBAL_END
end

@testitem "an unusable feature form is rejected with a helpful error" begin
    import HarfBuzz
    # Tuples, Dicts and NamedTuples are not accepted: a Dict is unordered
    # and none of them can express a range or a repeated tag.
    for bad in (("kern", 0), Dict("kern" => 0), (kern = 0,), 42)
        err = try
            HarfBuzz._as_feature(bad)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("kern=0", sprint(showerror, err))
    end
end

@testitem "a repeated tag over two ranges differs from either alone" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    text = "AVAWTo"
    default = [p.x_advance for p in HarfBuzz.shape(font, text).positions]
    global_off = [p.x_advance for p in
                  HarfBuzz.shape(font, text; features = ["kern=0"]).positions]
    @test default != global_off

    # Same tag twice over different ranges -- impossible with a Dict or a
    # NamedTuple, which is why neither is accepted.
    split = [p.x_advance for p in
             HarfBuzz.shape(font, text;
                            features = ["kern[0:2]=0", "kern[2:6]=1"]).positions]
    @test split != default
    @test split != global_off

    # Order matters: the last entry for a tag wins.
    last_wins = [p.x_advance for p in
                 HarfBuzz.shape(font, text;
                                features = ["kern=0", "kern=1"]).positions]
    @test last_wins == default
end

@testitem "shape accepts Feature values and strings" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    text = "AVAWTo"
    default = [p.x_advance for p in HarfBuzz.shape(font, text).positions]
    from_str = [p.x_advance for p in
                HarfBuzz.shape(font, text; features = ["kern=0"]).positions]
    from_obj = [p.x_advance for p in
                HarfBuzz.shape(font, text;
                               features = [HarfBuzz.Feature("kern=0")]).positions]
    @test from_str == from_obj
    @test default != from_str
end

# --- Shaping trace --------------------------------------------------------

@testitem "message func observes shaping stages" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    buf = HarfBuzz.Buffer()
    HarfBuzz.add_text!(buf, "Hello")
    HarfBuzz.guess_segment_properties!(buf)

    messages = String[]
    HarfBuzz.message_func!(buf, msg -> (push!(messages, msg); true))
    HarfBuzz.shape!(font, buf)
    @test !isempty(messages)
    @test any(m -> occursin("start", m), messages)
end

# --- Phase 3: glyph metrics ----------------------------------------------

@testitem "glyph advances" begin
    import HarfBuzz
    font = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    a = HarfBuzz.get_nominal_glyph(font, UInt32('A'))
    i = HarfBuzz.get_nominal_glyph(font, UInt32('i'))

    @test HarfBuzz.glyph_h_advance(font, a) > 0
    # Proportional font: "A" is wider than "i".
    @test HarfBuzz.glyph_h_advance(font, a) > HarfBuzz.glyph_h_advance(font, i)
    # No vertical metrics in this font: HarfBuzz synthesises them.
    @test HarfBuzz.glyph_v_advance(font, a) != 0

    # The batch form agrees with the scalar one.
    @test HarfBuzz.glyph_h_advances(font, [a, i]) ==
          [HarfBuzz.glyph_h_advance(font, a), HarfBuzz.glyph_h_advance(font, i)]

    # Advances match what shaping reports for the same glyphs.
    shaped = HarfBuzz.shape(font, "Ai")
    @test [p.x_advance for p in shaped.positions] ==
          HarfBuzz.glyph_h_advances(font, HarfBuzz.glyph_ids(shaped))
end

@testitem "glyph extents" begin
    import HarfBuzz
    font = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    a = HarfBuzz.get_nominal_glyph(font, UInt32('A'))
    space = HarfBuzz.get_nominal_glyph(font, UInt32(' '))

    e = HarfBuzz.glyph_extents(font, a)
    @test e isa HarfBuzz.GlyphExtents
    @test e.width > 0
    # y grows upward, so a cap-height glyph has positive bearing and
    # negative height.
    @test e.y_bearing > 0
    @test e.height < 0

    # A space draws nothing.
    es = HarfBuzz.glyph_extents(font, space)
    @test es === nothing || es.width == 0
end

@testitem "font extents" begin
    import HarfBuzz
    font = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    e = HarfBuzz.font_extents(font)
    @test e isa HarfBuzz.FontExtents
    @test e.ascender > 0
    @test e.descender < 0
    @test e.line_gap >= 0
    @test HarfBuzz.font_extents(font; direction = :ttb) isa HarfBuzz.FontExtents
end

@testitem "glyph origins and legacy kerning" begin
    import HarfBuzz
    font = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    a = HarfBuzz.get_nominal_glyph(font, UInt32('A'))
    # Horizontal origin is at the pen position for a horizontal font.
    @test HarfBuzz.glyph_h_origin(font, a) == (0, 0)
    @test HarfBuzz.glyph_v_origin(font, a) isa Tuple{Int,Int}
    # The test font kerns through GPOS, not the legacy kern table.
    @test HarfBuzz.glyph_h_kerning(font, a, a) == 0
end

# --- Phase 3: glyph names -------------------------------------------------

@testitem "glyph names round-trip" begin
    import HarfBuzz
    font = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    a = HarfBuzz.get_nominal_glyph(font, UInt32('A'))
    name = HarfBuzz.glyph_name(font, a)
    @test name == "A"
    @test HarfBuzz.glyph_from_name(font, "A") == a
    @test HarfBuzz.glyph_from_name(font, "no_such_glyph") === nothing
end

# --- Phase 3: face coverage ----------------------------------------------

@testitem "face unicode coverage" begin
    import HarfBuzz
    face = HarfBuzz.Face(Main.TEST_FONT)
    cps = HarfBuzz.unicodes(face)
    @test cps isa Set{UInt32}
    @test UInt32('A') in cps
    @test UInt32('é') in cps
    @test !(UInt32(0x6f22) in cps)         # 漢, outside the subset
    @test length(cps) < 200                # a subset, not a full font
end

# --- Phase 3: name table --------------------------------------------------

@testitem "name table lookup" begin
    import HarfBuzz
    face = HarfBuzz.Face(Main.TEST_FONT)
    @test occursin("Noto", HarfBuzz.name(face, :family))
    @test HarfBuzz.name(face, :subfamily) == "Regular"
    @test occursin("Copyright", HarfBuzz.name(face, :copyright))
    @test occursin("Noto", HarfBuzz.name(face, :postscript_name))
    # The subset carries no licence record, so a valid id can still be absent.
    @test HarfBuzz.name(face, :license) === nothing
    # Numeric ids work too, and a missing one is `nothing`.
    @test HarfBuzz.name(face, 1) == HarfBuzz.name(face, :family)
    @test HarfBuzz.name(face, 0xFFF0) === nothing
    @test_throws ArgumentError HarfBuzz.name(face, :not_a_name_id)
end

@testitem "name table listing" begin
    import HarfBuzz
    face = HarfBuzz.Face(Main.TEST_FONT)
    entries = HarfBuzz.name_entries(face)
    @test !isempty(entries)
    @test all(e -> haskey(e, :name_id) && haskey(e, :language), entries)
    @test 1 in [e.name_id for e in entries]     # family name is always there
end

# --- Phase 3: OpenType metrics and style ----------------------------------

@testitem "OpenType metrics" begin
    import HarfBuzz
    font = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    x = HarfBuzz.metric(font, :x_height)
    cap = HarfBuzz.metric(font, :cap_height)
    @test x isa Integer && x > 0
    @test cap isa Integer && cap > x        # caps are taller than x-height
    @test HarfBuzz.metric(font, :underline_offset) < 0
    @test HarfBuzz.metric(font, :horizontal_ascender) > 0
    @test_throws ArgumentError HarfBuzz.metric(font, :not_a_metric)
end

@testitem "style values" begin
    import HarfBuzz
    font = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    @test HarfBuzz.style(font, :italic) == 0
    @test HarfBuzz.style(font, :slant_angle) == 0
    @test_throws ArgumentError HarfBuzz.style(font, :not_a_style)

    # `style` reads STAT and fvar, so it follows the variations set on the
    # font. (Weight is asserted on the variable font: the upstream static
    # Noto Sans declares the family minimums in its STAT table, not its own
    # instance values.)
    varf = HarfBuzz.Font(Main.TEST_FONT_VAR; size = 18)
    @test HarfBuzz.style(varf, :weight) ≈ 400
    @test HarfBuzz.style(varf, :width) ≈ 100
    HarfBuzz.set_variations!(varf, ["wght" => 700])
    @test HarfBuzz.style(varf, :weight) ≈ 700
end

# --- Phase 3: variable fonts ----------------------------------------------

@testitem "variation axes" begin
    import HarfBuzz
    plain = HarfBuzz.Face(Main.TEST_FONT)
    varf = HarfBuzz.Face(Main.TEST_FONT_VAR)

    @test !HarfBuzz.has_variations(plain)
    @test isempty(HarfBuzz.axes(plain))

    @test HarfBuzz.has_variations(varf)
    ax = HarfBuzz.axes(varf)
    @test length(ax) == 2
    wght = only(filter(a -> a.tag == "wght", ax))
    @test wght.min_value ≈ 100
    @test wght.default_value ≈ 400
    @test wght.max_value ≈ 900
    @test "wdth" in [a.tag for a in ax]
end

@testitem "named instances" begin
    import HarfBuzz
    varf = HarfBuzz.Face(Main.TEST_FONT_VAR)
    inst = HarfBuzz.named_instances(varf)
    @test length(inst) == 9
    @test all(i -> length(i.coords) == 2, inst)
    @test any(i -> occursin("Bold", i.name), inst)
end

@testitem "setting variations changes shaping" begin
    import HarfBuzz
    face = HarfBuzz.Face(Main.TEST_FONT_VAR)

    adv(w) = begin
        f = HarfBuzz.Font(face; size = 18)
        HarfBuzz.set_variations!(f, ["wght" => w])
        [p.x_advance for p in HarfBuzz.shape(f, "Hi").positions]
    end
    thin, regular, black = adv(100), adv(400), adv(900)
    @test thin != regular != black
    # Heavier strokes are wider.
    @test all(black .>= regular .>= thin)

    f = HarfBuzz.Font(face; size = 18)
    HarfBuzz.set_variations!(f, ["wght" => 700])
    @test HarfBuzz.var_coords_design(f)[1] ≈ 700
    @test length(HarfBuzz.var_coords_normalized(f)) == 2
end

# --- Phase 3: OpenType layout --------------------------------------------

@testitem "layout table introspection" begin
    import HarfBuzz
    face = HarfBuzz.Face(Main.TEST_FONT)
    @test HarfBuzz.has_substitution(face)
    @test HarfBuzz.has_positioning(face)
    @test HarfBuzz.has_glyph_classes(face)

    scripts = HarfBuzz.layout_script_tags(face, :GSUB)
    @test !isempty(scripts)
    @test all(s -> length(s) == 4, scripts)

    features = HarfBuzz.layout_feature_tags(face, :GSUB)
    @test "liga" in features
    @test "kern" in HarfBuzz.layout_feature_tags(face, :GPOS)
    @test_throws ArgumentError HarfBuzz.layout_feature_tags(face, :GPOX)
end

@testitem "glyph classes from GDEF" begin
    import HarfBuzz
    face = HarfBuzz.Face(Main.TEST_FONT)
    font = HarfBuzz.Font(face; size = 18)
    a = HarfBuzz.get_nominal_glyph(font, UInt32('A'))
    @test HarfBuzz.glyph_class(face, a) == :base_glyph

    # The "ffi" ligature glyph is classified as such.
    lig = HarfBuzz.glyph_ids(HarfBuzz.shape(font, "office"))[2]
    @test HarfBuzz.glyph_class(face, lig) == :ligature
end

@testitem "baselines" begin
    import HarfBuzz
    font = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    # The roman baseline is at the origin for horizontal Latin text.
    @test HarfBuzz.baseline(font, :romn) == 0
    # A fallback is always produced, even for a tag the font lacks.
    @test HarfBuzz.baseline(font, :hang) isa Integer
    @test_throws ArgumentError HarfBuzz.baseline(font, :nope)
end

# --- Phase 3: font state deferred from Phase 1 ---------------------------

@testitem "synthetic bold and slant" begin
    import HarfBuzz
    face = HarfBuzz.Face(Main.TEST_FONT)

    plain = HarfBuzz.Font(face; size = 18)
    @test !HarfBuzz.is_synthetic(plain)
    @test HarfBuzz.synthetic_slant(plain) == 0

    slanted = HarfBuzz.Font(face; size = 18)
    HarfBuzz.synthetic_slant!(slanted, 0.25)
    @test HarfBuzz.synthetic_slant(slanted) ≈ 0.25
    @test HarfBuzz.is_synthetic(slanted)

    bold = HarfBuzz.Font(face; size = 18)
    HarfBuzz.synthetic_bold!(bold, 0.02, 0.02)
    @test HarfBuzz.synthetic_bold(bold)[1] ≈ 0.02 atol = 1e-6
    @test HarfBuzz.is_synthetic(bold)
end

@testitem "sub-fonts and immutability" begin
    import HarfBuzz
    parent = HarfBuzz.Font(Main.TEST_FONT; size = 18)
    child = HarfBuzz.sub_font(parent)
    @test HarfBuzz.scale(child) == HarfBuzz.scale(parent)
    HarfBuzz.scale!(child, (100, 100))
    @test HarfBuzz.scale(child) == (100, 100)
    @test HarfBuzz.scale(parent) == (18 * 64, 18 * 64)   # parent untouched

    @test !HarfBuzz.is_immutable(parent)
    HarfBuzz.make_immutable!(parent)
    @test HarfBuzz.is_immutable(parent)
end

# --- Phase 0 regression tests --------------------------------------------

@testitem "every shaped glyph has a non-zero advance" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    result = HarfBuzz.shape(font, "Hello")
    @test length(result.positions) == 5
    # Reading positions with the wrong stride left every entry after the
    # first at zero, so the last glyph is the one that matters here.
    @test all(p -> p.x_advance > 0, result.positions)
    @test result.positions[end].x_advance > 0
    # Plain ASCII in a horizontal run: no offsets, no vertical advance.
    @test all(p -> p.x_offset == 0 && p.y_offset == 0, result.positions)
    @test all(p -> p.y_advance == 0, result.positions)
end

@testitem "features are built over the whole buffer" begin
    import HarfBuzz
    f = HarfBuzz._make_feature("kern", 0)
    @test f.tag == HarfBuzz.tag("kern")
    @test f.value == 0
    @test f.start == HarfBuzz.HB_FEATURE_GLOBAL_START
    # An `end` of 0 is an empty range, which makes the feature a no-op.
    @test f.stop == HarfBuzz.HB_FEATURE_GLOBAL_END
    @test f.stop != 0
end

@testitem "disabling kerning changes advances" begin
    import HarfBuzz
    path = Main.TEST_FONT
    font = HarfBuzz.Font(path; size = 18)
    text = "AVAWTo"
    default = [p.x_advance for p in HarfBuzz.shape(font, text).positions]
    nokern = [p.x_advance for p in
              HarfBuzz.shape(font, text; features = ["kern" => 0]).positions]
    @test default != nokern
    # Disabling kerning can only widen: every pair loses its negative
    # adjustment.
    @test all(nokern .>= default)
end

@testitem "a font can be destroyed without crashing" begin
    import HarfBuzz
    path = Main.TEST_FONT
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
