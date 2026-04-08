const FIXTURES = joinpath(@__DIR__, "fixtures")

# ── load ──────────────────────────────────────────────────────────────────────

@testset "load: basic" begin
    spec = ParamIO.load(joinpath(FIXTURES, "basic.toml"))

    @test spec.study.project_name == "test_basic"
    @test spec.study.total_samples == 3
    @test spec.study.outdir == "out"
    @test spec.path_keys == ["system.N", "system.chi", "model.g", "model.h"]
    @test length(spec.paramsets) == 1
end

# ── expand ────────────────────────────────────────────────────────────────────

@testset "expand: basic Cartesian product × samples" begin
    spec = ParamIO.load(joinpath(FIXTURES, "basic.toml"))
    keys = ParamIO.expand(spec)

    # 2 values of N × 1 value of g × 3 samples = 6 DataKeys
    @test length(keys) == 6

    samples = [k.sample for k in keys]
    @test sort(unique(samples)) == [1, 2, 3]

    Ns = [k.params["system.N"] for k in keys]
    @test sort(unique(Ns)) == [24, 48]

    # chi is a fixed scalar — all keys have chi == 40
    @test all(k.params["system.chi"] == 40 for k in keys)
end

@testset "expand: multi-block union" begin
    spec = ParamIO.load(joinpath(FIXTURES, "multi_block.toml"))
    keys = ParamIO.expand(spec)

    # Block 1: 2N × 1g = 2 points
    # Block 2: 2N × 3h = 6 points  (g=1.0, h sweeps)
    # 8 unique param points × 2 samples = 16
    @test length(keys) == 16

    gs = unique([k.params["model.g"] for k in keys])
    @test sort(gs) == [0.5, 1.0]
end

@testset "expand: no duplicate param points across blocks" begin
    # Create a spec that has a deliberately repeated point
    spec = ParamIO.load(joinpath(FIXTURES, "multi_block.toml"))
    keys = ParamIO.expand(spec)

    # Check uniqueness of (params, sample) pairs
    pairs = [(k.params, k.sample) for k in keys]
    @test length(pairs) == length(unique(pairs))
end

# ── format_path ───────────────────────────────────────────────────────────────

@testset "format_path: plain keys" begin
    params = Dict{String,Any}("N" => 24, "chi" => 40, "g" => 0.5, "h" => 0.0)
    key = DataKey(params, 1)
    path_keys = ["N", "chi", "g", "h"]

    result = ParamIO.format_path(key, path_keys)
    @test result == "N24_chi40_g0.50_h0.00"
end

@testset "format_path: dotted keys add group prefix" begin
    params = Dict{String,Any}(
        "system.N" => 24, "system.chi" => 40, "model.g" => 0.5, "model.h" => 0.0
    )
    key = DataKey(params, 1)
    path_keys = ["system.N", "system.chi", "model.g", "model.h"]

    result = ParamIO.format_path(key, path_keys)
    @test result == "sysN24_syschi40_modg0.50_modh0.00"
end

@testset "format_path: integer and float formatting" begin
    params = Dict{String,Any}("N" => 128, "beta" => 10.0, "mu" => -0.5)
    key = DataKey(params, 1)
    path_keys = ["N", "beta", "mu"]

    result = ParamIO.format_path(key, path_keys)
    @test result == "N128_beta10.00_mu-0.50"
end

# ── resolve_path_keys ─────────────────────────────────────────────────────────

@testset "resolve_path_keys: auto from unique leaves" begin
    spec = ParamIO.load(joinpath(FIXTURES, "auto_path_keys.toml"))
    # All leaf names are unique: N, chi, g, h
    @test sort(spec.path_keys) == sort(["system.N", "system.chi", "model.g", "model.h"])
end

@testset "resolve_path_keys: ambiguous leaf → error" begin
    @test_throws ParamIO.AmbiguousPathKeyError begin
        ParamIO.load(joinpath(FIXTURES, "ambiguous.toml"))
    end
end

# ── config inheritance ────────────────────────────────────────────────────────

@testset "load: inheritance concatenates paramsets" begin
    spec = ParamIO.load(joinpath(FIXTURES, "child.toml"))

    # parent has 1 block, child adds 1 block → 2 blocks total
    @test length(spec.paramsets) == 2

    # study and path_keys come from parent
    @test spec.study.project_name == "test_inherit"
    @test spec.path_keys == ["system.N", "system.chi", "model.g", "model.h"]

    # expand: parent block (1 pt) + child block (1 pt) × 2 samples = 4 keys
    keys = ParamIO.expand(spec)
    @test length(keys) == 4

    Ns = sort(unique([k.params["system.N"] for k in keys]))
    @test Ns == [24, 64]
end

# ── DataKey equality and hashing ──────────────────────────────────────────────

@testset "DataKey equality and Set deduplication" begin
    p1 = Dict{String,Any}("N" => 24, "g" => 1.0)
    p2 = Dict{String,Any}("N" => 24, "g" => 1.0)
    p3 = Dict{String,Any}("N" => 48, "g" => 1.0)

    k1 = DataKey(p1, 1)
    k2 = DataKey(p2, 1)
    k3 = DataKey(p3, 1)

    @test k1 == k2
    @test k1 != k3

    s = Set([k1, k2, k3])
    @test length(s) == 2
end
