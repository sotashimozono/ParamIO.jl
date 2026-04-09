"""
test_format_path_edge.jl — format_path のエッジケース網羅

既存テストは hot path だけだったので、以下を追加する：
- 値の型 (Int, Float, 負数, ゼロ, 文字列, Bool)
- path_keys の順序保存
- dotted + plain の混在
- leaf-only ルックアップ
- 欠損キー時のエラー
- 曖昧なリーフ名のエラー
"""

@testset "format_path: 値の型バリエーション" begin
    @testset "Int / Float / 負数 / ゼロ" begin
        params = Dict{String,Any}("N" => 0, "g" => 0.0, "h" => -0.5, "M" => -3)
        key = DataKey(params, 1)
        @test ParamIO.format_path(key, ["N", "g", "h", "M"]) == "N0_g0.00_h-0.50_M-3"
    end

    @testset "文字列値はそのまま埋め込み" begin
        params = Dict{String,Any}("model" => "TFIML", "N" => 24)
        key = DataKey(params, 1)
        @test ParamIO.format_path(key, ["model", "N"]) == "modelTFIML_N24"
    end

    @testset "Float の小数点以下2桁固定" begin
        params = Dict{String,Any}("g" => 1.234567)
        key = DataKey(params, 1)
        @test ParamIO.format_path(key, ["g"]) == "g1.23"
    end

    @testset "Float の e-notation 入力" begin
        params = Dict{String,Any}("eps" => 1.0e-6)
        key = DataKey(params, 1)
        # 0.00 になるが panic しないこと
        @test ParamIO.format_path(key, ["eps"]) == "eps0.00"
    end
end

@testset "format_path: path_keys の順序を保存" begin
    params = Dict{String,Any}("a" => 1, "b" => 2, "c" => 3)
    key = DataKey(params, 1)
    @test ParamIO.format_path(key, ["a", "b", "c"]) == "a1_b2_c3"
    @test ParamIO.format_path(key, ["c", "b", "a"]) == "c3_b2_a1"
    @test ParamIO.format_path(key, ["b", "a"]) == "b2_a1"
end

@testset "format_path: dotted と plain の混在" begin
    # dotted の system.N と plain の chi が同じパスに出現
    params = Dict{String,Any}("system.N" => 24, "chi" => 40)
    key = DataKey(params, 1)
    @test ParamIO.format_path(key, ["system.N", "chi"]) == "sysN24_chi40"
end

@testset "format_path: leaf-only ルックアップ（dotted を plain で参照）" begin
    # params に dotted で入っていても、path_keys に plain で書けば leaf 名で引ける
    params = Dict{String,Any}("model.g" => 0.5)
    key = DataKey(params, 1)
    # plain leaf 名で format → group prefix なし
    @test ParamIO.format_path(key, ["g"]) == "g0.50"
end

@testset "format_path: 曖昧な leaf → エラー" begin
    # system.N と model.N の両方があるとき、plain "N" は曖昧
    params = Dict{String,Any}("system.N" => 24, "model.N" => 8)
    key = DataKey(params, 1)
    @test_throws Exception ParamIO.format_path(key, ["N"])
end

@testset "format_path: 欠損 path_key → エラー" begin
    params = Dict{String,Any}("N" => 24)
    key = DataKey(params, 1)
    @test_throws Exception ParamIO.format_path(key, ["nonexistent"])
end

@testset "format_path: 単一 key" begin
    params = Dict{String,Any}("N" => 24)
    key = DataKey(params, 1)
    @test ParamIO.format_path(key, ["N"]) == "N24"
end

@testset "format_path: dotted prefix が3文字未満のグループ" begin
    # group の長さが2文字 ("xy") の場合、prefix も2文字 (現実装は length(group) >= 3 で 3文字)
    params = Dict{String,Any}("xy.N" => 24)
    key = DataKey(params, 1)
    result = ParamIO.format_path(key, ["xy.N"])
    @test occursin("N24", result)
    @test startswith(result, "xy")  # 短いグループ名はそのまま prefix に
end

@testset "format_path: dotted prefix が長いグループは3文字に切詰め" begin
    params = Dict{String,Any}("system.N" => 24)
    key = DataKey(params, 1)
    @test ParamIO.format_path(key, ["system.N"]) == "sysN24"
end
