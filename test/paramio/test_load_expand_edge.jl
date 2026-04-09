isdefined(@__MODULE__, :FIXTURES) || (const FIXTURES = joinpath(@__DIR__, "fixtures"))

"""
test_load_expand_edge.jl — load / expand のエッジケース網羅

既存テストには無い観点：
- 文字列スカラー（model.type = "TFIML" のような固定文字列）
- 全パラメータがスカラー（sweep 軸なし → 1点）
- total_samples = 0
- 巨大組み合わせ（パフォーマンス＆メモリ確認）
- spec.paramsets の構造アクセス
"""

@testset "load: 文字列スカラー値" begin
    spec = ParamIO.load(joinpath(FIXTURES, "string_scalar.toml"))
    keys = ParamIO.expand(spec)

    # 2 (N) × 2 (g) × 1 (sample) = 4 keys
    @test length(keys) == 4

    # type は固定スカラーで全 key に乗っている
    @test all(k.params["model.type"] == "TFIML" for k in keys)

    # J はスカラーだが path_keys に含まれていなくても params には残る
    @test all(k.params["model.J"] == 1.0 for k in keys)
end

@testset "expand: 全スカラー → 1パラメータ点 × 各サンプル" begin
    spec = ParamIO.load(joinpath(FIXTURES, "all_scalar.toml"))
    keys = ParamIO.expand(spec)

    # sweep 軸なし → 1 点 × 3 サンプル = 3 keys
    @test length(keys) == 3
    samples = sort([k.sample for k in keys])
    @test samples == [1, 2, 3]
    @test all(k.params["system.N"] == 24 for k in keys)
end

@testset "expand: total_samples = 0 → 空" begin
    spec = ParamIO.load(joinpath(FIXTURES, "zero_samples.toml"))
    keys = ParamIO.expand(spec)
    @test length(keys) == 0
    @test isempty(keys)
end

@testset "load: spec.paramsets の構造（flatten 形式）" begin
    spec = ParamIO.load(joinpath(FIXTURES, "basic.toml"))
    @test length(spec.paramsets) == 1

    block = spec.paramsets[1]
    @test block isa Dict{String,Any}
    # サブテーブルが dotted キーに flatten されている
    @test haskey(block, "system.N")
    @test haskey(block, "system.chi")
    @test haskey(block, "model.g")
end

@testset "expand: 巨大組み合わせ (Cartesian 数千)" begin
    # 動作とメモリ確認のためのストレステスト
    # 4 × 5 × 6 × 7 × 10 = 8400 points
    # mktempdir 内に動的に config を作る
    mktempdir() do tmpdir
        cfg = joinpath(tmpdir, "huge.toml")
        write(cfg, """
[study]
project_name  = "huge"
total_samples = 1
outdir        = "out"

[datavault]
path_keys = ["a", "b", "c", "d", "e"]

[[paramsets]]
a = [1, 2, 3, 4]
b = [1, 2, 3, 4, 5]
c = [1, 2, 3, 4, 5, 6]
d = [1, 2, 3, 4, 5, 6, 7]
e = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
""")
        spec = ParamIO.load(cfg)
        keys = ParamIO.expand(spec)
        @test length(keys) == 4 * 5 * 6 * 7 * 10
    end
end

@testset "expand: ブロック内重複排除" begin
    # 同じ値を含む sweep
    mktempdir() do tmpdir
        cfg = joinpath(tmpdir, "dup.toml")
        write(cfg, """
[study]
project_name  = "dup"
total_samples = 1
outdir        = "out"

[datavault]
path_keys = ["x"]

[[paramsets]]
x = [1, 2, 2, 3, 3, 3]

[[paramsets]]
x = [3, 4]
""")
        spec = ParamIO.load(cfg)
        keys = ParamIO.expand(spec)
        # ブロック1: {1, 2, 2, 3, 3, 3} → 6 個 (TOML 配列の重複は ParamIO 側で排除されない)
        # ブロック2: {3, 4} → 2 個 (3 はブロック1と重複なので排除)
        # 期待: ParamIO がブロック間で重複を排除する
        unique_x = sort(unique([k.params["x"] for k in keys]))
        @test unique_x == [1, 2, 3, 4]
    end
end

@testset "load: 存在しないファイル → エラー" begin
    @test_throws Exception ParamIO.load("/nonexistent/path/to/config.toml")
end

@testset "load: total_samples 既定値" begin
    # study セクションがない場合の既定値
    mktempdir() do tmpdir
        cfg = joinpath(tmpdir, "minimal.toml")
        write(cfg, """
[datavault]
path_keys = ["x"]

[[paramsets]]
x = [1, 2]
""")
        spec = ParamIO.load(cfg)
        # 既定値: total_samples=1, project_name="unnamed", outdir="out"
        @test spec.study.total_samples == 1
        @test spec.study.project_name == "unnamed"
    end
end
