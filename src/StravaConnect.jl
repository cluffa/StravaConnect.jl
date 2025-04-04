module StravaConnect

using HTTP
using URIs
using JSON3
using Dates
using JLD2
using PrecompileTools: @setup_workload, @compile_workload

export setup_user, get_activity_list, get_activity, reduce_subdicts!, fill_dicts!

const DATA_DIR = get(ENV, "STRAVA_DATA_DIR", tempdir())

const HIDE = true
const STREAMKEYS = ("time", "distance", "latlng", "altitude", "velocity_smooth", "heartrate", "cadence", "watts", "temp", "moving", "grade_smooth")

# conversions
const METER_TO_MILE = 0.000621371
const METER_TO_FEET = 3.28084
c2f(c::Number)::Number = (c * 9/5) + 32

include("oauth.jl")

"""
    activites_list_api(access_token::String, page::Int, per_page::Int, after::Int; dry_run::Bool = false) -> HTTP.Response

Fetch a paginated list of activities from the Strava API.

# Arguments
- `access_token::String`: OAuth access token for authentication.
- `page::Int`: Page number to fetch.
- `per_page::Int`: Number of activities per page.
- `after::Int`: Unix timestamp to filter activities after this time.
- `dry_run::Bool`: If true, returns test data instead of making an API call (default: false).

# Returns
- `HTTP.Response`: HTTP response containing the activities data.
"""
function activites_list_api(access_token::String, page::Int, per_page::Int, after::Int; dry_run::Bool = false)::Union{HTTP.Response, Nothing}
    if dry_run
        return HTTP.Response(
            read("./test/activites_list_api.json")
        )
    else 
        resp = HTTP.get(
            "https://www.strava.com/api/v3/athlete/activities?page=$page&per_page=$per_page&after=$after",
            headers = Dict("Authorization" => "Bearer $(access_token)"),
            status_exception = false  # Don't throw an exception for non-200 responses
        )

        if resp.status == 429
            @warn "Rate limit exceeded, no new activities will be fetched."
            return nothing
        elseif resp.status != 200
            @error "Error getting activities"
            return nothing
        end
    
        return resp
    end
end

"""
    activity_api(access_token::String, id::Int; dry_run::Bool = false) -> HTTP.Response

Fetch detailed data for a specific activity from the Strava API.

# Arguments
- `access_token::String`: OAuth access token for authentication.
- `id::Int`: Activity ID to retrieve.
- `dry_run::Bool`: If true, returns test data instead of making an API call (default: false).

# Returns
- `HTTP.Response`: HTTP response containing the activity data.
"""
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
            ),
            status_exception = false  # Don't throw an exception for non-200 responses
        )

        if response.status == 429;
            @warn "Rate limit exceeded, waiting 5 minutes before retrying."
            sleep(300)  # Wait for 5 minutes before retrying
            return activity_api(access_token, id; dry_run)  # retry the request after waiting
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
- `d::AbstractDict`: Dictionary potentially containing nested dictionaries.

# Returns
- `AbstractDict`: Flattened dictionary with nested keys merged into top-level keys.
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

"""
    reduce_subdicts!(dicts::Vector{Dict{Symbol, Any}}) -> Vector{Dict{Symbol, Any}}

Apply `reduce_subdicts!` to each dictionary in a vector.

# Arguments
- `dicts::Vector{Dict{Symbol, Any}}`: Vector of dictionaries to flatten.

# Returns
- `Vector{Dict{Symbol, Any}}`: Vector of flattened dictionaries.
"""
reduce_subdicts!(dicts::Vector{Dict{Symbol, Any}}) = map(reduce_subdicts!, dicts)

"""
    fill_dicts!(dicts::Vector{Dict{Symbol, Any}}) -> Vector{Dict{Symbol, Any}}

Ensure all dictionaries in a vector have the same keys by filling missing keys with `nothing`.

# Arguments
- `dicts::Vector{Dict{Symbol, Any}}`: Vector of dictionaries to fill.

# Returns
- `Vector{Dict{Symbol, Any}}`: Vector of dictionaries with consistent keys.
"""
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
    get_activity_list(u::User; data_dir::String = DATA_DIR, dry_run::Bool = false) -> Vector{Dict}

Retrieve a list of all activities for a user, with optional caching.

# Arguments
- `u::User`: Authorized user struct.
- `data_dir::String`: Directory for caching data (default: `DATA_DIR`).
- `dry_run::Bool`: If true, uses test data instead of making API calls (default: false).

# Returns
- `Vector{Dict}`: List of activity dictionaries.
"""
function get_activity_list(u::User; data_dir::String = DATA_DIR, dry_run = false)
    refresh_if_needed!(u)
    data_file = joinpath(data_dir, "data.jld2")

    T = Vector{Dict{Symbol, Union{Dict{Symbol, Any}, Any}}}

    mtime = 0
    list = T(undef, 0)
    if !dry_run
        if !isdir(data_dir)
            mkpath(data_dir)
        end

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

        if isnothing(resp)
            break
        end

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
    get_activity(id::Int, u::User; data_dir::String = DATA_DIR, dry_run::Bool = false) -> Dict{Symbol, Any}

Retrieve detailed data for a specific activity, with optional caching.

# Arguments
- `id::Int`: Activity ID to retrieve.
- `u::User`: Authorized user struct.
- `data_dir::String`: Directory for caching data (default: `DATA_DIR`).
- `dry_run::Bool`: If true, uses test data instead of making API calls (default: false).

# Returns
- `Dict{Symbol, Any}`: Activity data including streams.
"""
function get_activity(id::Int, u::User; data_dir::String = DATA_DIR, dry_run::Bool = false, verbose::Bool = false)::Dict{Symbol, Any}
    refresh_if_needed!(u)
    T = Dict{Symbol, Dict{Symbol, Any}}

    data_file = joinpath(data_dir, "data.jld2")
    
    jldopen(data_file, "a+") do io
        if haskey(io, "activity_$id")
            activity = io["activity_$id"]

            if verbose
                @info "Loaded activity $id from cache"
            end

            return activity
        end
    
        response = activity_api(u.access_token, id; dry_run)
        activity = JSON3.read(response.body, T)

        if verbose
            @info "Fetched activity $id from API"
        end
        
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

        # get_activity_list(u; dry_run = true)
        # get_activity(1, u; dry_run = true)
        
        redirect_stdout(real_stdout)
    end
end

"""
    clear_data()

Delete all cached data files in the `DATA_DIR`.

# Arguments
- None.

# Returns
- Nothing.
"""
function clear_data()
    rm(joinpath(DATA_DIR, "data.jld2"), force = true)
end

end  # module
