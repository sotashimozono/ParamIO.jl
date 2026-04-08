module ParamIO

using TOML, Printf

export ConfigSpec, StudySpec, DataKey, AmbiguousPathKeyError
export load, expand, format_path, resolve_path_keys

# ── Errors ────────────────────────────────────────────────────────────────────

struct AmbiguousPathKeyError <: Exception
    leaf::String
    groups::Vector{String}
end

function Base.showerror(io::IO, e::AmbiguousPathKeyError)
    hint = "\"$(e.groups[1]).$(e.leaf)\""
    print(
        io,
        "AmbiguousPathKeyError: leaf \"$(e.leaf)\" appears in groups: ",
        join(e.groups, ", "),
        ". Use dotted notation (e.g., $hint) in [datavault] path_keys to disambiguate.",
    )
end

# ── Structs ───────────────────────────────────────────────────────────────────

struct StudySpec
    project_name::String
    total_samples::Int
    outdir::String
end

"""
    ConfigSpec

Parsed representation of a config TOML.

Fields:
- `study`:     project-level metadata
- `path_keys`: ordered keys used to build directory paths (dotted or plain)
- `paramsets`: flattened [[paramsets]] blocks; each is a `Dict{String,Any}`
               where sub-table keys are prefixed as `"group.leaf"`
"""
struct ConfigSpec
    study::StudySpec
    path_keys::Vector{String}
    paramsets::Vector{Dict{String,Any}}
end

"""
    DataKey

A single point in the parameter space, including sample index.
`params` keys match the dotted/plain scheme used in the config's `path_keys`.
"""
struct DataKey
    params::Dict{String,Any}
    sample::Int
end

Base.:(==)(a::DataKey, b::DataKey) = a.sample == b.sample && a.params == b.params
Base.hash(k::DataKey, h::UInt) = hash(k.sample, hash(k.params, h))

# ── Public API ────────────────────────────────────────────────────────────────

"""
    load(path; inherit=true) -> ConfigSpec

Read a TOML config and return a `ConfigSpec`.
If `[base] inherit = "..."` is present, merge the parent file first
(parent `[[paramsets]]` come first in the union).
"""
function load(path::AbstractString; inherit::Bool=true)::ConfigSpec
    raw = TOML.parsefile(path)

    if inherit && haskey(raw, "base") && haskey(raw["base"], "inherit")
        parent_path = joinpath(dirname(path), raw["base"]["inherit"])
        parent_raw = TOML.parsefile(parent_path)
        raw = _merge_configs(parent_raw, raw)
    end

    study_tbl = get(raw, "study", Dict{String,Any}())
    study = StudySpec(
        get(study_tbl, "project_name", "unnamed"),
        get(study_tbl, "total_samples", 1),
        get(study_tbl, "outdir", "out"),
    )

    raw_paramsets = get(raw, "paramsets", Vector{Dict{String,Any}}())
    flat_blocks = [_flatten_block(b) for b in raw_paramsets]

    if haskey(raw, "datavault") && haskey(raw["datavault"], "path_keys")
        path_keys = convert(Vector{String}, raw["datavault"]["path_keys"])
        _validate_path_keys(path_keys, flat_blocks)
    else
        path_keys = resolve_path_keys(flat_blocks)
    end

    ConfigSpec(study, path_keys, flat_blocks)
end

"""
    expand(spec) -> Vector{DataKey}

Expand all `[[paramsets]]` blocks via Cartesian product,
deduplicate across blocks, and return one `DataKey` per (param_point × sample).
"""
function expand(spec::ConfigSpec)::Vector{DataKey}
    seen = Set{Dict{String,Any}}()
    points = Dict{String,Any}[]

    for block in spec.paramsets
        for pt in _cartesian_product(block)
            if pt ∉ seen
                push!(seen, pt)
                push!(points, pt)
            end
        end
    end

    result = DataKey[]
    for pt in points
        for s in 1:spec.study.total_samples
            push!(result, DataKey(pt, s))
        end
    end
    result
end

"""
    format_path(key, path_keys) -> String

Build a compact path segment from a `DataKey`.

Examples:
- plain key `"N"`, value `24`         → `"N24"`
- dotted key `"system.N"`, value `24` → `"sysN24"` (3-char group prefix)
- float value                         → two decimal places: `"g0.50"`
"""
function format_path(key::DataKey, path_keys::Vector{String})::String
    parts = String[]
    for pk in path_keys
        val = get(key.params, pk, nothing)
        if val !== nothing
            # Exact match (dotted "system.N" or top-level "N")
            push!(parts, _format_param(pk, val))
        else
            # pk is a plain leaf name — find it in params by leaf match
            _, leaf = _split_dotted(pk)
            leaf == pk || error("path_key \"$pk\" not found in DataKey.params")
            matches = [(k, v) for (k, v) in key.params if _split_dotted(k)[2] == pk]
            isempty(matches) && error("path_key \"$pk\" not found in DataKey.params")
            length(matches) > 1 && error(
                "Ambiguous leaf \"$pk\" in DataKey.params — use dotted notation. " *
                "Matches: $(join([m[1] for m in matches], ", "))")
            # Plain name → format WITHOUT group prefix (user chose plain name intentionally)
            push!(parts, _format_val(pk, matches[1][2]))
        end
    end
    join(parts, "_")
end

"""
    resolve_path_keys(flat_blocks) -> Vector{String}

Auto-detect `path_keys` from flattened paramset blocks (sorted).
Raises `AmbiguousPathKeyError` when the same leaf name appears in multiple groups
and the caller has not supplied explicit dotted notation.
"""
function resolve_path_keys(flat_blocks::Vector{Dict{String,Any}})::Vector{String}
    all_keys = Set{String}()
    for b in flat_blocks
        union!(all_keys, keys(b))
    end

    # leaf → set of groups it belongs to ("" for top-level keys)
    leaf_groups = Dict{String,Set{String}}()
    for k in all_keys
        group, leaf = _split_dotted(k)
        grps = get!(leaf_groups, leaf, Set{String}())
        push!(grps, group)
    end

    for (leaf, grps) in leaf_groups
        real = sort(filter(!isempty, collect(grps)))
        length(real) > 1 && throw(AmbiguousPathKeyError(leaf, real))
    end

    sort(collect(all_keys))
end

# ── Internals ─────────────────────────────────────────────────────────────────

# "group.leaf" → ("group", "leaf");  "leaf" → ("", "leaf")
function _split_dotted(k::String)
    idx = findfirst('.', k)
    idx === nothing && return ("", k)
    return (k[1:(idx - 1)], k[(idx + 1):end])
end

# Flatten one [[paramsets]] block: sub-tables become dotted top-level keys.
# {"system" => {"N" => [24,48], "chi" => 40}} → {"system.N" => [24,48], "system.chi" => 40}
function _flatten_block(block::Dict)::Dict{String,Any}
    result = Dict{String,Any}()
    for (k, v) in block
        if v isa Dict
            for (sk, sv) in v
                result["$k.$sk"] = sv
            end
        else
            result[string(k)] = v
        end
    end
    result
end

# All Cartesian combinations of array-valued keys; scalars stay fixed.
function _cartesian_product(flat::Dict{String,Any})::Vector{Dict{String,Any}}
    sweep_keys = [k for (k, v) in flat if v isa AbstractArray]
    fixed = Dict{String,Any}(k => v for (k, v) in flat if !(v isa AbstractArray))

    isempty(sweep_keys) && return [copy(fixed)]

    ranges = [flat[k] for k in sweep_keys]
    result = Dict{String,Any}[]

    function recurse(idx::Int, current::Dict{String,Any})
        if idx > length(sweep_keys)
            push!(result, merge(fixed, current))
            return nothing
        end
        for val in ranges[idx]
            recurse(idx + 1, merge(current, Dict{String,Any}(sweep_keys[idx] => val)))
        end
    end
    recurse(1, Dict{String,Any}())
    result
end

# Format one path_key + value: "sysN24", "chi40", "g0.50"
function _format_param(pk::String, val)::String
    group, leaf = _split_dotted(pk)
    prefix = isempty(group) ? "" : (length(group) >= 3 ? group[1:3] : group)
    return prefix * _format_val(leaf, val)
end

function _format_val(name::String, val)::String
    val isa AbstractFloat && return @sprintf("%s%.2f", name, val)
    val isa Integer && return @sprintf("%s%d", name, val)
    return "$(name)$(val)"
end

# Merge two raw TOML dicts; child overrides parent.
# [[paramsets]] arrays are concatenated (parent first).
function _merge_configs(parent::Dict{String,Any}, child::Dict{String,Any})::Dict{String,Any}
    result = deepcopy(parent)
    for (k, v) in child
        if k == "paramsets" && haskey(result, "paramsets")
            result["paramsets"] = vcat(result["paramsets"], v)
        elseif v isa Dict && haskey(result, k) && result[k] isa Dict
            result[k] = _merge_configs(result[k], v)
        else
            result[k] = v
        end
    end
    result
end

function _validate_path_keys(
    path_keys::Vector{String}, flat_blocks::Vector{Dict{String,Any}}
)
    all_keys = Set{String}()
    for b in flat_blocks
        union!(all_keys, keys(b))
    end
    for pk in path_keys
        pk ∈ all_keys && continue  # exact match (dotted or top-level)
        # Try as plain leaf name
        _, leaf = _split_dotted(pk)
        if leaf == pk  # pk has no dot → plain leaf lookup
            matches = [k for k in all_keys if _split_dotted(k)[2] == pk]
            if length(matches) == 1
                continue  # found exactly one → OK
            elseif length(matches) > 1
                groups = sort([_split_dotted(k)[1] for k in matches])
                throw(AmbiguousPathKeyError(pk, groups))
            end
        end
        avail = join(sort(collect(all_keys)), ", ")
        error("path_key \"$pk\" not found in any paramset block. Available: $avail")
    end
end

end # module ParamIO
