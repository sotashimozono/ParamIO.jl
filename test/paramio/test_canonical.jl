using ParamIO, Test

@testset "canonical(::DataKey)" begin
    @testset "determinism" begin
        k1 = DataKey(Dict{String,Any}("N" => 8, "J" => 1.0), 3)
        k2 = DataKey(Dict{String,Any}("N" => 8, "J" => 1.0), 3)
        @test canonical(k1) == canonical(k2)
        # same object twice
        @test canonical(k1) == canonical(k1)
    end

    @testset "order-independent" begin
        a = DataKey(Dict{String,Any}("N" => 8, "J" => 1.0), 3)
        b = DataKey(Dict{String,Any}("J" => 1.0, "N" => 8), 3)
        @test canonical(a) == canonical(b)
    end

    @testset "schema fixed" begin
        k = DataKey(Dict{String,Any}("N" => 8, "J" => 1.0), 3)
        @test canonical(k) == "J=1.0;N=8;#sample=3"
    end

    @testset "Float round-trip" begin
        k = DataKey(Dict{String,Any}("x" => 0.1 + 0.2), 0)
        s = canonical(k)
        # Extract value portion between "x=" and ";#sample"
        mid = s[length("x=")+1:findlast(';', s)-1]
        @test parse(Float64, mid) === 0.1 + 0.2
    end

    @testset "Float edge cases" begin
        @test occursin("NaN", canonical(DataKey(Dict{String,Any}("v" => NaN), 0)))
        @test occursin("Inf", canonical(DataKey(Dict{String,Any}("v" => Inf), 0)))
        @test occursin("-Inf", canonical(DataKey(Dict{String,Any}("v" => -Inf), 0)))
    end

    @testset "Symbol vs String distinguished" begin
        sym = DataKey(Dict{String,Any}("a" => :x), 0)
        str = DataKey(Dict{String,Any}("a" => "x"), 0)
        @test canonical(sym) != canonical(str)
        @test canonical(sym) == "a=:x;#sample=0"
        @test canonical(str) == "a=\"x\";#sample=0"
    end

    @testset "String with quotes/backslashes escaped" begin
        k = DataKey(Dict{String,Any}("s" => "a\"b\\c"), 0)
        s = canonical(k)
        @test occursin("\\\"", s)
        @test occursin("\\\\", s)
    end

    @testset "Bool / Int / Nothing" begin
        @test canonical(DataKey(Dict{String,Any}("b" => true), 0)) == "b=true;#sample=0"
        @test canonical(DataKey(Dict{String,Any}("b" => false), 0)) == "b=false;#sample=0"
        @test canonical(DataKey(Dict{String,Any}("i" => 42), 0)) == "i=42;#sample=0"
        @test canonical(DataKey(Dict{String,Any}("n" => nothing), 0)) == "n=nothing;#sample=0"
    end

    @testset "sample index always last" begin
        k = DataKey(Dict{String,Any}("z" => 1), 9)
        @test endswith(canonical(k), "#sample=9")
    end

    @testset "empty params" begin
        k = DataKey(Dict{String,Any}(), 7)
        @test canonical(k) == "#sample=7"
    end

    @testset "existing == and hash unchanged" begin
        a = DataKey(Dict{String,Any}("N" => 8), 1)
        b = DataKey(Dict{String,Any}("N" => 8), 1)
        c = DataKey(Dict{String,Any}("N" => 8), 2)
        @test a == b
        @test hash(a) == hash(b)
        @test a != c
    end
end
