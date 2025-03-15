module StravaConnect

using HTTP
using URIs
using JSON3
using Dates
using JLD2
using PrecompileTools: @setup_workload, @compile_workload

include("oauth.jl")

export setup_user, get_activity_list, get_activity, reduce_subdicts!, fill_dicts!

const DATA_DIR = "./data"
const HIDE = true
const STREAMKEYS = ("time", "distance", "latlng", "altitude", "velocity_smooth", "heartrate", "cadence", "watts", "temp", "moving", "grade_smooth")

# conversions
const METER_TO_MILE = 0.000621371
const METER_TO_FEET = 3.28084
c2f(c::Number)::Number = (c * 9/5) + 32


function activites_list_api(access_token::String, page::Int, per_page::Int, after::Int; dry_run::Bool = false)
    if dry_run
        return HTTP.Response(
            read("./test/activites_list_api.json")
        )
    else 
        resp = HTTP.get(
            "https://www.strava.com/api/v3/athlete/activities?page=$page&per_page=$per_page&after=$after",
            headers = Dict("Authorization" => "Bearer $(access_token)")
        )

        if resp.status == 429
            @error "Rate limit exceeded"
            return nothing
        elseif resp.status != 200
            @error "Error getting activities"
            return nothing
        end
    
        return resp
    end
end

function activity_api(access_token::String, id::Int; dry_run::Bool = false)::HTTP.Response
    if dry_run
        return HTTP.Response(
            read("./test/activity_api.json")
        )
    else
        response = HTTP.get(
            "https://www.strava.com/api/v3/activities/$id/streams?keys=$(join(STREAMKEYS, ","))&key_by_type=true",
            headers = Dict(
                "Authorization" => "Bearer $(access_token)",
                "accept" => "application/json"
            )
        )

        if response.status == 429;
            @info "Rate limit exceeded, waiting "
        elseif response.status != 200
            @error "Error getting activity"
        end

        return response
    end
end

"""
    reduce_subdicts!(d::AbstractDict) -> AbstractDict

Flatten nested dictionaries by combining keys with underscores.

# Arguments
- `d::AbstractDict`: Dictionary potentially containing nested dictionaries

# Returns
- `AbstractDict`: Flattened dictionary
"""
function reduce_subdicts!(d::AbstractDict)::AbstractDict
    for key in keys(d)
        if d[key] isa Dict
            for (k, v) in pop!(d, key)
                d[Symbol("$(key)_$(k)")] = v
            end
        end
    end
    return d
end

reduce_subdicts!(dicts::Vector{Dict{Symbol, Any}}) = map(reduce_subdicts!, dicts)

function fill_dicts!(dicts::Vector{Dict{Symbol, Any}})
    all_keys = unique(vcat(collect.(keys.(dicts))...))
    for d in dicts
        for k in all_keys
            if !haskey(d, k)
                d[k] = nothing
            end
        end
    end

    return dicts
end

"""
    get_activity_list(u::User; data_dir::String="./data", dry_run::Bool=false) -> Vector{Dict}

Get list of all activities for a user, with caching.

# Arguments
- `u::User`: Authorized user struct
- `data_dir::String`: Directory for caching data (default: "./data")
- `dry_run::Bool`: Use test data instead of API calls (default: false)

# Returns
- `Vector{Dict}`: List of activity dictionaries
"""
function get_activity_list(u::User; data_dir::String = DATA_DIR, dry_run = false)
    isdir(data_dir) || mkdir(data_dir)

    data_file = joinpath(data_dir, "data.jld2")

    T = Vector{Dict{Symbol, Union{Dict{Symbol, Any}, Any}}}

    mtime = 0
    list = T(undef, 0)
    if !dry_run
        jldopen(data_file, "a+") do io       
            if haskey(io, "activities") && haskey(io, "mtime")
                mtime = io["mtime"]
                append!(list, io["activities"])
            end
        end

        @info "$(length(list)) activities loaded from cache, getting activities after $(unix2datetime(mtime))"
    end

    n_cache = length(list)
    per_page = 200

    page = 1
    while true
        resp = activites_list_api(u.access_token, page, per_page, mtime; dry_run)

        data = JSON3.read(resp.body, T)
        
        if length(data) == 0
            break
        end

        append!(list, data)
        
        if length(data) < per_page
            break
        end

        page += 1
    end

    if !dry_run
        @info "$(length(list) - n_cache) new activities loaded, total $(length(list)) activities"
        jldsave(data_file; activities = list, mtime = Int(floor(time())))
    end

    return list
end

"""
    get_activity(id::Int, u::User; data_dir::String="./data", dry_run::Bool=false) -> Dict{Symbol, Any}

Get detailed data for a specific activity.

# Arguments
- `id::Int`: Activity ID to retrieve
- `u::User`: Authorized user struct
- `data_dir::String`: Directory for caching data (default: "./data")
- `dry_run::Bool`: Use test data instead of API calls (default: false)

# Returns
- `Dict{Symbol, Any}`: Activity data including streams
"""
function get_activity(id::Int, u::User; data_dir::String = DATA_DIR, dry_run::Bool = false)::Dict{Symbol, Any}
    isdir(data_dir) || mkdir(data_dir)

    T = Dict{Symbol, Dict{Symbol, Any}}

    data_file = joinpath(data_dir, "data.jld2")
    
    jldopen(data_file, "a+") do io
        if haskey(io, "activity_$id")
            activity = io["activity_$id"]
            return activity
        end
    
        response = activity_api(u.access_token, id; dry_run)
        activity = JSON3.read(response.body, T)
        
        if !dry_run
            io["activity_$id"] = activity
        end

        activity
    end
end

@setup_workload begin
    # Putting some things in `@setup_workload` instead of `@compile_workload` can reduce the size of the
    # precompile file and potentially make loading faster.

    @compile_workload begin
        # all calls in this block will be precompiled, regardless of whether
        # they belong to your package or not (on Julia 1.8 and higher)
        real_stdout = stdout
        (rd, wr) = redirect_stdout();

        u = User()
        d = Dict{Symbol, Any}(:a => Dict(:b => 1))
        d2 = Dict{Symbol, Any}(:c => 2)

        reduce_subdicts!(d)
        fill_dicts!([d, d2])

        get_activity_list(u; dry_run = true)
        get_activity(1, u; dry_run = true)
        
        redirect_stdout(real_stdout)
    end
end

end  # module
