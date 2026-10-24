using CRDSClient, Test, Logging, Random
using CRDSClient: parse_literal, parse_assignments, Call, condition_value, pyfloatstr, reformat_date, matcher, match_value,
                  parse_mapping, choose, evaluate, LookupFailure, ValidationFailure, fetch_file, cache_paths
import SHA

# Offline unit tests first, then live comparisons with the CRDS servers (skipped when unreachable).

include("server_compare.jl")

const LIVE = Dict("roman" => ["roman_0040.pmap", "roman_0058.pmap", "roman_0072.pmap", "latest"],
                  "jwst" => ["jwst_1000.pmap", "jwst_1584.pmap", "latest"])

function reachable(obs)
    get(ENV, "CRDSCLIENT_SKIP_ONLINE", "0") == "1" && return false
    try
        CRDSClient.rpc(obs, "get_server_info"; mode = :auto, tries = 1)
        return true
    catch e
        @warn "$obs CRDS server unreachable: skipping its live tests" exception = e
        return false
    end
end

@testset "CRDSClient" begin

@testset "Python literal parser" begin
    @test parse_literal("{'a' : ('x', 'y',), 'b' : [1, 2.5, -3e2], 'c' : None, 'd' : True}") ==
          Dict("a" => ("x", "y"), "b" => Any[1, 2.5, -300.0], "c" => nothing, "d" => true)
    @test parse_literal("('only')") == "only"            # parentheses, not a tuple
    @test parse_literal("('one',)") == ("one",)
    @test parse_literal("()") == ()
    @test parse_literal("'a' \"b\" '''c'''") == "abc"     # adjacent literals concatenate
    @test parse_literal("Match({ 'X' : UseAfter({ '2020-01-01 00:00:00' : 'f.asdf' }) })") ==
          Call("Match", Any[Dict("X" => Call("UseAfter", Any[Dict("2020-01-01 00:00:00" => "f.asdf")]))])
    a = parse_assignments("# comment\nheader = {\n 'name' : 'x.rmap', # trailing\n}\n\nselector = Match({})\n")
    @test a["header"]["name"] == "x.rmap" && a["selector"] == Call("Match", Any[Dict()])
    @test_throws CRDSError parse_literal("{'a' : 1, 'a' : 2}")
    @test_throws CRDSError parse_literal("{'a' : 1")
    @test_throws "line 2" parse_assignments("header = {\n 'a' : }")
end

@testset "value conditioning" begin
    # Python repr of floats
    @test pyfloatstr(1.0) == "1.0" && pyfloatstr(1e-5) == "1e-05" && pyfloatstr(1e16) == "1e+16"
    @test pyfloatstr(1e15) == "1000000000000000.0" && pyfloatstr(0.0001) == "0.0001" && pyfloatstr(-2.5e-7) == "-2.5e-07"
    @test pyfloatstr(123.456) == "123.456" && pyfloatstr(0.1) == "0.1"
    @test condition_value(" f158 ") == "F158"
    @test condition_value("5") == "5.0" && condition_value(5) == "5.0" && condition_value("1e-5") == "1e-05"
    @test condition_value("any") == "*" && condition_value("n/a") == "N/A" && condition_value("NOT APPLICABLE") == "N/A"
    @test condition_value(true) == "T" && condition_value("false") == "F" && condition_value(nothing) == "NONE"
    @test reformat_date("2026-10-02T03:25:39.356") == "2026-10-02 03:25:39.356000"
    @test reformat_date("2026-10-02 03:25:39") == "2026-10-02 03:25:39"
    @test reformat_date("2026/10/02") == "2026-10-02 00:00:00"
    @test reformat_date(CRDSClient.Dates.DateTime(2026, 10, 2, 3, 25, 39)) == "2026-10-02 03:25:39"
    @test_throws ArgumentError reformat_date("2026-02-30 00:00:00")
    @test_throws ArgumentError reformat_date("yesterday")
end

@testset "matchers (the Python client's doctests)" begin
    m = matcher("fo*o|bar*|baz")
    @test [match_value(m, v) for v in ("far", "fo", "foo", "fo1o", "baz", "ba", "bar12")] == [-1, -1, 1, 1, 1, -1, 1]
    p = matcher(" UVIS-SUB-QUAD  |  UVIS-SUB-W2K  ")
    @test match_value(p, "UVIS-SUB-QUAD") == 1 && match_value(p, "UVIS-SUB") == -1
    @test match_value(p, "*") == 1 && match_value(p, "N/A") == 0
    m = matcher(">1.2")
    @test [match_value(m, v) for v in ("1.3", "1.2", "-100", "*", "N/A")] == [1, -1, -1, 1, 0]
    m = matcher("<1.2")
    @test [match_value(m, v) for v in ("1.3", "1.2", "-100")] == [-1, -1, 1]
    m = matcher("between 1 3")
    @test [match_value(m, v) for v in ("1.0", "2.5", "3.0")] == [1, 1, -1]
    @test match_value(matcher("NOT F158"), "F087") == 1 && match_value(matcher("NOT F158"), "F158") == -1
    @test match_value(matcher("N/A"), "ANYTHING") == 0
    @test match_value(matcher("{a|b}"), "a|b") == 1 && match_value(matcher("{a|b}"), "a") == -1   # literal
    @test match_value(matcher(("F062", "F087")), "F087") == 1
end

rmap(selector; header_extra = "") = parse_mapping("t_inst_kind_0001.rmap", """
header = {
    'filekind' : 'KIND', 'instrument' : 'INST', 'mapping' : 'REFERENCE', 'name' : 't_inst_kind_0001.rmap',
    'observatory' : 'T', 'parkey' : (('DET', 'FILT'), ('START',)), $header_extra
}
selector = $selector
""")

@testset "Match and UseAfter" begin
    r = rmap("""Match({
        ('D1', 'F1') : UseAfter({'2020-01-01 00:00:00' : 'exact_old', '2025-01-01 00:00:00' : 'exact_new'}),
        ('D1', 'N/A') : UseAfter({'2020-01-01 00:00:00' : 'any_filter'}),
        ('D2', 'F1|F2') : UseAfter({'2020-01-01 00:00:00' : 'alt'}),
        ('D3', 'F1') : 'N/A',
        ('*', 'F9') : UseAfter({'2020-01-01 00:00:00' : 'wild'}),
    })""")
    h(d, f, s = "2026-01-01 00:00:00") = Dict("DET" => d, "FILT" => f, "START" => s)
    @test evaluate(r, h("D1", "F1")) == (:found, "exact_new")                 # two exact matches beat one
    @test evaluate(r, h("D1", "F1", "2021-06-01T00:00:00")) == (:found, "exact_old")
    @test evaluate(r, h("D1", "F1", "2025-01-01 00:00:00")) == (:found, "exact_new")   # UseAfter is <=
    @test evaluate(r, h("D1", "F2")) == (:found, "any_filter")                # N/A = don't care
    @test evaluate(r, h("D2", "F2")) == (:found, "alt")
    @test evaluate(r, h("D3", "F1")) == (:na, "")
    @test evaluate(r, h("D7", "F9")) == (:found, "wild")
    # the exact clause has no date before 2019: falls back to the N/A clause, as the Python client
    @test evaluate(r, h("D1", "F1", "2019-01-01 00:00:00")) == (:failed, "No match found. (No selection <= '2019-01-01 00:00:00')")
    # a wildcard clause exempts DET from the listed-values check, as in the Python client
    @test evaluate(r, h("D9", "F1")) == (:failed, "No match found.")
    st, msg = evaluate(rmap("Match({('D1', 'F1') : UseAfter({'2020-01-01 00:00:00' : 'x'})})"), h("D9", "F1"))
    @test st === :failed && msg == "parameter='DET' value='D9' is not in ['D1']"
    @test evaluate(r, Dict("DET" => "D1", "FILT" => "F1"))[1] === :failed     # START undefined

    # equally good clauses: their UseAfters merge (later date wins; same date, greater name)
    r2 = rmap("""Match({
        ('D1', 'N/A') : UseAfter({'2020-01-01 00:00:00' : 'a', '2024-01-01 00:00:00' : 'c'}),
        ('N/A', 'F1') : UseAfter({'2022-01-01 00:00:00' : 'b', '2024-01-01 00:00:00' : 'd'}),
    })""")
    @test evaluate(r2, h("D1", "F1", "2023-01-01 00:00:00")) == (:found, "b")
    @test evaluate(r2, h("D1", "F1", "2025-01-01 00:00:00")) == (:found, "d")
    # substitutions in the rmap header; optional types are N/A when nothing matches
    r3 = rmap("Match({('D1', 'GENERIC') : UseAfter({'2020-01-01 00:00:00' : 'g'})})";
              header_extra = "'substitutions' : {'FILT' : {'GENERIC' : 'N/A'}}, 'reffile_required' : 'NO',")
    @test evaluate(r3, h("D1", "F5")) == (:found, "g")
    @test evaluate(r3, h("D2", "F5")) == (:na, "")
    # rules this package does not evaluate are left to the server
    @test evaluate(rmap("SelectVersion({'<1' : 'x'})"), h("D1", "F1"))[1] === :unsupported
    @test evaluate(rmap("Match({})"; header_extra = "'rmap_relevance' : '(FILT != \"F1\")',"), h("D1", "F1"))[1] === :unsupported
end

@testset "VersionAfter (the Python client's doctests)" begin
    r = parse_mapping("jwst_system_t_0001.rmap", """
header = {'filekind' : 'T', 'instrument' : 'SYSTEM', 'mapping' : 'REFERENCE', 'name' : 'jwst_system_t_0001.rmap',
          'observatory' : 'JWST', 'parkey' : (('CAL_VER',),)}
selector = VersionAfter({'0.0.2' : 'test_0.json', '0.50.1' : 'test_1.json', '5.2' : 'test_2.json', '50.1' : 'test_3.json'})
""")
    for (v, f) in ("0.0.2" => "test_0.json", "0.5.0" => "test_0.json", "0.50.0" => "test_0.json", "49.1" => "test_2.json",
                   "50.0" => "test_2.json", "0.6.0" => "test_0.json", "100.0.0" => "test_3.json", "0.50.1rc2.dev3+g12" => "test_1.json")
        @test evaluate(r, Dict("CAL_VER" => v)) == (:found, f)
    end
    @test evaluate(r, Dict("CAL_VER" => "0.0.1")) == (:failed, "No selection <= '0.0.1'")
    @test evaluate(r, Dict{String, String}())[1] === :failed          # UNDEFINED is not a version
end

@testset "JWST FITS keywords" begin
    jwst_parkey, condition_header = CRDSClient.jwst_parkey, CRDSClient.condition_header
    @test jwst_parkey("EXP_TYPE") == "META.EXPOSURE.TYPE" && jwst_parkey("OPMODE") == "META.INSTRUMENT.LAMP_MODE"
    @test jwst_parkey("META.ANYTHING") == "META.ANYTHING" && jwst_parkey("NOT_A_KEYWORD") == "NOT_A_KEYWORD"
    h = condition_header("jwst", Dict("exp_type" => "nrc_image", "META.EXPOSURE.TYPE" => "MIR_IMAGE", "DETECTOR" => "nrca1"))
    @test h == Dict("META.EXPOSURE.TYPE" => "MIR_IMAGE", "META.INSTRUMENT.DETECTOR" => "NRCA1")   # explicit key wins
    @test condition_header("roman", Dict("EXP_TYPE" => "x")) == Dict("EXP_TYPE" => "X")        # JWST only
end

@testset "cache paths (the Python client's precedence)" begin
    keys_ = ("CRDS_MAPPATH_SINGLE", "CRDS_MAPPATH", "CRDS_PATH_SINGLE", "CRDS_PATH", "CRDS_DEFAULT_CACHE",
             "CRDS_REFPATH_SINGLE", "CRDS_REFPATH", "CRDS_CFGPATH_SINGLE", "CRDS_CFGPATH")
    clear = [k => nothing for k in keys_]
    withenv(clear..., "CRDS_DEFAULT_CACHE" => "/d") do
        @test cache_paths("roman").mappings == "/d/mappings/roman"
    end
    withenv(clear..., "CRDS_DEFAULT_CACHE" => "/d", "CRDS_PATH" => "/p") do
        @test cache_paths("jwst") == (; mappings = "/p/mappings/jwst", references = "/p/references/jwst", config = "/p/config/jwst")
    end
    withenv(clear..., "CRDS_PATH" => "/p", "CRDS_PATH_SINGLE" => "/s") do
        @test cache_paths("roman").references == "/s/references"
    end
    withenv(clear..., "CRDS_PATH_SINGLE" => "/s", "CRDS_MAPPATH" => "/m", "CRDS_REFPATH_SINGLE" => "/r") do
        c = cache_paths("roman")
        @test c.mappings == "/m/roman" && c.references == "/r" && c.config == "/s/config"
    end
    withenv(clear..., "CRDS_MAPPATH" => "/m", "CRDS_MAPPATH_SINGLE" => "/ms") do
        @test cache_paths("roman").mappings == "/ms"
    end
    withenv(clear...) do
        @test startswith(cache_paths("roman").mappings, CRDSClient.scratch_cache())   # no variables: scratch space
    end
end

@testset "downloads: checks and one fetch per file across threads" begin
    src = mktempdir()
    payload = rand(UInt8, 3_000_000)
    write(joinpath(src, "f.bin"), payload)
    url = "file://" * joinpath(src, "f.bin")
    sha = bytes2hex(SHA.sha1(payload))
    dst = mktempdir()
    @test_throws CRDSError fetch_file("roman", url, joinpath(dst, "bad_size"); mode = :auto, size = 1, tries = 1)
    @test_throws CRDSError fetch_file("roman", url, joinpath(dst, "bad_sha"); mode = :auto, sha1sum = "0"^40, tries = 1)
    @test !isfile(joinpath(dst, "bad_size")) && !isfile(joinpath(dst, "bad_sha"))
    @test_throws CRDSOfflineError fetch_file("roman", url, joinpath(dst, "local"); mode = :local)
    logger = Test.TestLogger()
    dest = joinpath(dst, "f.bin")
    with_logger(logger) do
        @sync for _ in 1:8
            Threads.@spawn fetch_file("roman", url, dest; mode = :auto, size = length(payload), sha1sum = sha)
        end
    end
    @test read(dest) == payload
    @test count(r -> occursin("downloading", string(r.message)), logger.logs) == 1
    @test isempty(filter(f -> endswith(f, ".part") || occursin("lock", f), readdir(dst)))
end
# --- live tests: against the CRDS servers ---------------------------------------------------
# Each observatory's tests are skipped (not failed) when its server cannot be reached, or when
# CRDSCLIENT_SKIP_ONLINE=1.  They use the normal cache (CRDS_PATH etc., else the package's scratch
# space), so the immutable rule files are downloaded once, not on every run; each comparison is one
# batched request for all of a context's headers.  CRDS_SERVER_URL is unset here: each observatory
# uses its own server.

withenv("CRDS_SERVER_URL" => nothing) do
    for obs in ("roman", "jwst")
        @testset "live: $obs server" begin
            if !reachable(obs)
                @test_skip "server unreachable"
            else
                withenv("CRDS_ALLOW_BAD_REFERENCES" => "1", "CRDS_ALLOW_BAD_RULES" => "1") do
                    ctxs = [resolve_context(c; observatory = obs) for c in LIVE[obs]]
                    @test all(endswith(".pmap"), ctxs)
                    @test compare_contexts(ctxs; obs, n = 300, fits = obs == "jwst", io = devnull) == 0
                end
            end
        end
    end

    @testset "live: public interface" begin
        if !reachable("roman")
            @test_skip "server unreachable"
        else
            h = Dict("ROMAN.META.INSTRUMENT.NAME" => "WFI", "ROMAN.META.INSTRUMENT.DETECTOR" => "WFI02",
                     "ROMAN.META.INSTRUMENT.OPTICAL_ELEMENT" => "F087", "ROMAN.META.EXPOSURE.START_TIME" => "2026-10-02T03:25:39.356",
                     "ROMAN.META.EXPOSURE.TYPE" => "WFI_IMAGE")
            r = best_references(h; context = "roman_0058.pmap", reftypes = ["EPSF", "dustmap"])
            @test r == Dict("epsf" => "roman_wfi_epsf_0266.asdf", "dustmap" => "N/A")
            @test best_references(h; context = "roman_0058.pmap", reftypes = ["epsf", "dustmap"], mode = :local) == r   # now cached
            @test best_references(h; context = "roman_0058.pmap", reftypes = ["epsf", "dustmap"], mode = :remote) == r
            # META.* keys get the ROMAN. prefix, as the Python client does
            @test best_references(Dict(replace(k, "ROMAN." => "") => v for (k, v) in h); context = "roman_0058.pmap",
                                  reftypes = ["epsf"]) == Dict("epsf" => "roman_wfi_epsf_0266.asdf")
            e = try
                best_references(merge(h, Dict("ROMAN.META.INSTRUMENT.DETECTOR" => "WFI99")); context = "roman_0058.pmap", reftypes = ["area", "epsf"])
            catch err
                err
            end
            @test e isa CRDSLookupError && collect(keys(e.failures)) == ["area"]
            @test occursin("value='WFI99' is not in", e.failures["area"])
            @test occursin("ROMAN.META.INSTRUMENT.DETECTOR", sprint(showerror, e))
            @test "ROMAN.META.EXPOSURE.START_TIME" in required_parkeys("roman_0058.pmap"; reftypes = ["epsf"])
            @test resolve_context("roman-2026-10-01") == "roman_0072.pmap"
            p = get_references(h; context = "roman_0072.pmap", reftypes = ["apcorr"])["apcorr"]   # a small file
            @test isfile(p) && endswith(p, joinpath("wfi", basename(p)))
            # local mode with nothing cached: a clear error, no network (the in-memory mapping and
            # server-information caches are cleared so the empty cache folders are what is seen)
            withenv("CRDS_MAPPATH_SINGLE" => mktempdir(), "CRDS_CFGPATH_SINGLE" => mktempdir()) do
                empty!(CRDSClient.MAPPINGS); empty!(CRDSClient.SESSION_INFO)
                @test_throws CRDSOfflineError best_references(h; context = "roman_0058.pmap", mode = :local)
                @test_throws CRDSOfflineError resolve_context("latest"; observatory = "roman", mode = :local)
                empty!(CRDSClient.MAPPINGS); empty!(CRDSClient.SESSION_INFO)
            end
        end
    end
end

end
