module StravaConnect

using HTTP
using URIs
using JSON3
using Dates
using JLD2
using PrecompileTools: @setup_workload, @compile_workload

export setup_user, get_or_setup_user,
    get_activity_list, get_cached_activity_list, get_cached_activity_ids,
    get_activity, get_activity_stream, get_cached_activity, get_cached_activity_stream,
    reduce_subdicts!, fill_dicts!

const DATA_DIR = get(ENV, "STRAVA_DATA_DIR", tempdir())

const HIDE = true
const STREAMKEYS = ("time", "distance", "latlng", "altitude", "velocity_smooth", "heartrate", "cadence", "watts", "temp", "moving", "grade_smooth")

FloatType = Float32
IntType = Int32
const STREAM_TYPES = Dict{Symbol, Type}(
    :time => Int, # always 64-bit
    :distance => FloatType,
    :latlng => Tuple{FloatType, FloatType},
    :altitude => FloatType,
    :velocity_smooth => FloatType,
    :heartrate => FloatType,
    :cadence => IntType,
    :watts => IntType,
    :temp => IntType,
    :moving => Bool,
    :grade_smooth => FloatType,
)

# conversions
const METER_TO_MILE = 0.000621371
const METER_TO_FEET = 3.28084
c2f(c::Number)::Number = (c * 9/5) + 32

include("oauth.jl")

"""
    activites_list_api(u::User, page::Int, per_page::Int, after::Int) -> HTTP.Response

Fetch a paginated list of activities from the Strava API.

# Arguments
- `u::User`: Authorized user struct.
- `page::Int`: Page number to fetch.
- `per_page::Int`: Number of activities per page.
- `after::Int`: Unix timestamp to filter activities after this time.

# Returns
- `HTTP.Response`: HTTP response containing the activities data.
"""
function activities_list_api(u::User, page::Int, per_page::Int, after::Int)::Union{HTTP.Response, Nothing}
    resp = HTTP.get(
        "https://www.strava.com/api/v3/athlete/activities?page=$page&per_page=$per_page&after=$after",
        headers = Dict("Authorization" => "Bearer $(u.access_token)"),
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

"""
    activity_api(u::User, id::Int; wait_on_rate_limit::Bool = true) -> HTTP.Response

Fetch detailed data for a specific activity from the Strava API.

# Arguments
- `u::User`: Authorized user struct.
- `id::Int`: Activity ID to retrieve.
- `wait_on_rate_limit::Bool`: If true, waits and retries when rate limit is exceeded (default: true). If false, throws an error on rate limit.

# Returns
- `HTTP.Response`: HTTP response containing the activity data.

# Throws
- `ErrorException` if rate limit is exceeded and `wait_on_rate_limit` is false.
"""
function activity_api(u::User, id::Int; wait_on_rate_limit::Bool = true)::HTTP.Response
    response = HTTP.get(
        "https://www.strava.com/api/v3/activities/$id/streams?keys=$(join(STREAMKEYS, ","))&key_by_type=true",
        headers = Dict(
            "Authorization" => "Bearer $(u.access_token)",
            "accept" => "application/json"
        ),
        status_exception = false  # Don't throw an exception for non-200 responses
    )

    if response.status == 429
        if wait_on_rate_limit
            @warn "Rate limit exceeded, waiting 5 minutes before retrying."
            sleep(300)  # Wait for 5 minutes before retrying
            refresh_if_needed!(u)  # Ensure the token is still valid before retrying
            return activity_api(u, id; wait_on_rate_limit=wait_on_rate_limit)  # retry the request after waiting
        else
            error("Rate limit exceeded and wait_on_rate_limit is false. Aborting request.")
        end
    end

    return response
end

"""
    reduce_subdicts!(d::Dict{Symbol, Any}) -> Dict{Symbol, Any}

Flatten nested dictionaries by combining keys with underscores.

# Arguments
- `d::Dict{Symbol, Any}`: Dictionary potentially containing nested dictionaries.

# Returns
- `Dict{Symbol, Any}`: Flattened dictionary with nested keys merged into top-level keys.
"""
function reduce_subdicts!(d::Dict{Symbol, Any})::Dict{Symbol, Any}
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
reduce_subdicts!(dicts::Vector{Dict{Symbol, Any}})::Vector{Dict{Symbol, Any}} = map(reduce_subdicts!, dicts)

"""
    fill_dicts!(dicts::Vector{Dict{Symbol, Any}}) -> Vector{Dict{Symbol, Any}}

Ensure all dictionaries in a vector have the same keys by filling missing keys with `nothing`.

# Arguments
- `dicts::Vector{Dict{Symbol, Any}}`: Vector of dictionaries to fill.

# Returns
- `Vector{Dict{Symbol, Any}}`: Vector of dictionaries with consistent keys.
"""
function fill_dicts!(dicts::Vector{Dict{Symbol, Any}})::Vector{Dict{Symbol, Any}}
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
    get_activity_list(u::User; data_dir::String = DATA_DIR, force_update::Bool = false) -> Vector{Dict}

Retrieve a list of all activities for a user, with caching.

# Arguments
- `u::User`: Authorized user struct.
- `data_dir::String`: Directory for caching data (default: `DATA_DIR`).
- `force_update::Bool`: If true, always fetches from the API and updates the cache (default: false).

# Returns
- `Vector{Dict}`: List of activity dictionaries.

See also: [`get_activity_list(; ...)`](@ref) for a version that does not require a `User` argument.
"""
function get_activity_list(u::User; data_dir::String = DATA_DIR, force_update::Bool = false)::Vector{Dict{Symbol, Any}}
    refresh_if_needed!(u)
    data_file = joinpath(data_dir, "data.jld2")

    T = Vector{Dict{Symbol, Union{Dict{Symbol, Any}, Any}}}

    mtime = 0
    list = T(undef, 0)
    if !force_update
        if !isdir(data_dir)
            mkpath(data_dir)
        end

        jldopen(data_file, "a+") do io       
            if haskey(io, "activities") && haskey(io, "mtime")
                mtime = io["mtime"]
                append!(list, io["activities"])
            end
        end
        
        @info "$(length(list)) activities loaded from cache"
    else
        if !isdir(data_dir)
            mkpath(data_dir)
        end
        # force update: ignore cache, set mtime to 0
        mtime = 0
        list = T(undef, 0)
        @info "Force update: fetching all activities from API."
    end

    n_cache = length(list)
    
    # only run if mtime is more than 1 hour ago
    if mtime < time() - 3600 || force_update
        @info "Fetching activities after $(unix2datetime(mtime))"
 
        per_page = 200
        page = 1
        while true
            resp = activities_list_api(u, page, per_page, mtime)

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
    end

    if !force_update
        @info "$(length(list) - n_cache) new activities loaded, total $(length(list)) activities"
        jldopen(data_file, "a+") do io
            # only append new activities
            if haskey(io, "activities")
                append!(io["activities"], list[n_cache + 1:end])  # append only the new activities to the existing list
            else
                io["activities"] = list
            end

            delete!(io, "mtime")  # ensure we remove the old mtime if it exists
            io["mtime"] = Int(floor(time()))
        end
    else
        @info "Force update: overwriting cache with new activities."
        jldopen(data_file, "a+") do io
            delete!(io, "activities")  # remove the old activities
            delete!(io, "mtime")  # remove the old mtime
            io["activities"] = list
            io["mtime"] = Int(floor(time()))
        end
    end

    return list
end

"""
    get_activity_list(; data_dir::String = DATA_DIR, force_update::Bool = false) -> Vector{Dict}

Retrieve a list of all activities for the current user, with caching.

This version does not require a `User` argument; the user is loaded or created automatically and cached internally.

# Arguments
- `data_dir::String`: Directory for caching data (default: `DATA_DIR`).
- `force_update::Bool`: If true, always fetches from the API and updates the cache (default: false).

# Returns
- `Vector{Dict}`: List of activity dictionaries.
"""
function get_activity_list(; data_dir::String = DATA_DIR, force_update::Bool = false)::Vector{Dict{Symbol, Any}}
    u = get_or_setup_user()
    return get_activity_list(u; data_dir=data_dir, force_update=force_update)
end

"""
    get_activity(id::Int; data_dir::String = DATA_DIR, force_update::Bool = false, verbose::Bool = false, wait_on_rate_limit::Bool = true) -> Dict{Symbol, Any}

Retrieve detailed data for a specific activity for the current user, with caching.

This version does not require a `User` argument; the user is loaded or created automatically and cached internally.

# Arguments
- `id::Int`: Activity ID to retrieve.
- `data_dir::String`: Directory for caching data (default: `DATA_DIR`).
- `force_update::Bool`: If true, always fetches from the API and updates the cache (default: false).
- `verbose::Bool`: If true, prints info messages (default: false).
- `wait_on_rate_limit::Bool`: If true, waits and retries when rate limit is exceeded (default: true). If false, throws an error on rate limit.

# Returns
- `Dict{Symbol, Any}`: Activity data including streams.
"""
function get_activity(id::Int; data_dir::String = DATA_DIR, force_update::Bool = false, verbose::Bool = false, wait_on_rate_limit::Bool = true)::Dict{Symbol, Any}
    u = get_or_setup_user()
    return get_activity(id, u; data_dir=data_dir, force_update=force_update, verbose=verbose, wait_on_rate_limit=wait_on_rate_limit)
end

"""
    get_activity_stream(id::Int, stream::Symbol; data_dir::String = DATA_DIR, force_update::Bool = false, verbose::Bool = false, wait_on_rate_limit::Bool = true) -> Union{Dict{Symbol, Any}, Missing}

Retrieve a specific stream of data for a specific activity, with caching.

# Arguments
- `id::Int`: Activity ID to retrieve.
- `stream::Symbol`: The stream to retrieve (e.g., :latlng).
- `data_dir::String`: Directory for caching data (default: `DATA_DIR`).
- `force_update::Bool`: If true, always fetches from the API and updates the cache (default: false).
- `verbose::Bool`: If true, prints info messages (default: false).
- `wait_on_rate_limit::Bool`: If true, waits and retries when rate limit is exceeded (default: true). If false, throws an error on rate limit.
# Returns
- `Dict{Symbol, Any}`: The requested stream's data vector, or `missing` if not found.

"""
function get_activity_stream(id::Int, stream::Symbol; data_dir::String = DATA_DIR, force_update::Bool = false, verbose::Bool = false, wait_on_rate_limit::Bool = true)::Union{Dict{Symbol, Any}, Missing}
    activity = get_activity(id; data_dir=data_dir, force_update=force_update, verbose=verbose, wait_on_rate_limit=wait_on_rate_limit)
    if haskey(activity, stream)
        return activity[stream]
    else
        return missing
    end 
end

"""
    get_activity(id::Int, u::User; data_dir::String = DATA_DIR, force_update::Bool = false, verbose::Bool = false, wait_on_rate_limit::Bool = true) -> Dict{Symbol, Any}

Retrieve detailed data for a specific activity, with caching.

# Arguments
- `id::Int`: Activity ID to retrieve.
- `u::User`: Authorized user struct.
- `data_dir::String`: Directory for caching data (default: `DATA_DIR`).
- `force_update::Bool`: If true, always fetches from the API and updates the cache (default: false).
- `verbose::Bool`: If true, prints info messages (default: false).
- `wait_on_rate_limit::Bool`: If true, waits and retries when rate limit is exceeded (default: true). If false, throws an error on rate limit.

# Returns
- `Dict{Symbol, Any}`: Activity data including streams.

See also: [`get_activity(id; ...)`](@ref) for a version that does not require a `User` argument.
"""
function get_activity(id::Int, u::User; data_dir::String = DATA_DIR, force_update::Bool = false, verbose::Bool = false, wait_on_rate_limit::Bool = true)::Dict{Symbol, Any}
    refresh_if_needed!(u)
    T = Dict{Symbol, Dict{Symbol, Any}}

    data_file = joinpath(data_dir, "data.jld2")

    activity = Dict{Symbol, Any}()
    
    jldopen(data_file, "a+") do f
        if haskey(f, "activity/$id") && !force_update
            activity = Dict{Symbol, Any}()
            data = f["activity/$id"]

            for k in keys(data)
                activity[Symbol(k)] = data[k]
            end

            if verbose
                @info "Loaded activity $id from cache"
            end
        else
            response = activity_api(u, id; wait_on_rate_limit=wait_on_rate_limit)
            if response.status == 200
                activity = JSON3.read(response.body, T)

                if haskey(f, "activity/$id")
                    delete!(f, "activity/$id")  # remove the old activity if it exists
                end

                for k in keys(activity)
                    stream = activity[k]
                    T = STREAM_TYPES[k]
                    if any(isnothing.(stream[:data]))
                        stream[:data] = Union{T, Missing}[isnothing(x) ? missing : T(x) for x in stream[:data]]
                    else
                        stream[:data] = T[isnothing(x) ? missing : T(x) for x in stream[:data]]  # convert the data to the correct type
                    end
                    
                    f["activity/$id/$k"] = stream
                end

                if verbose
                    @info "Fetched activity $id from API"
                end
            elseif  response.status != 200
                @warn "Error getting activity $id: $(response.status) $(response.body)"
                return Dict{Symbol, Any}()  # return an empty dict if the request failed
            end
        end
    end

    return activity
end

"""
    get_cached_activity_list(data_dir::String = DATA_DIR) -> Vector{Dict{Symbol, Any}}

Load the cached list of activities from disk.

# Arguments
- `data_dir::String`: Directory for cached data (default: `DATA_DIR`).

# Returns
- `Vector{Dict{Symbol, Any}}`: List of activity dictionaries loaded from cache. Returns an empty vector if no cache is found.

This function does not contact the Strava API and only loads data previously cached by `get_activity_list`.
"""
function get_cached_activity_list(data_dir::String = DATA_DIR)::Vector{Dict{Symbol, Any}}
    if !isdir(data_dir)
        @warn "Data directory $data_dir does not exist."
        return Vector{Dict{Symbol, Any}}()
    elseif !isfile(joinpath(data_dir, "data.jld2"))
        @warn "No cached data found in $data_dir."
        return Vector{Dict{Symbol, Any}}()
    end

    data_file = joinpath(data_dir, "data.jld2")
    file = jldopen(data_file, "r") 
    out = get(file, "activities", Vector{Dict{Symbol, Any}}())  # return empty vector if key doesn't exist
    @info "Loaded cached activity list from $data_file with $(length(out)) activities."
    close(file)
    return out
end



"""
    get_cached_activity_ids(data_dir::String = DATA_DIR) -> Vector{Int}

Load the cached list of activity IDs from disk.

# Arguments
- `data_dir::String`: Directory for cached data (default: `DATA_DIR`).

# Returns
- `Vector{Int}`: List of activity IDs loaded from cache. Returns an empty vector if no cache is found.

This function does not contact the Strava API and only loads IDs previously cached by `get_activity` or `get_activity_list`.
"""
function get_cached_activity_ids(data_dir::String = DATA_DIR)::Vector{Int}
    if !isdir(data_dir)
        @warn "Data directory $data_dir does not exist."
        return Vector{Dict{Symbol, Any}}()
    elseif !isfile(joinpath(data_dir, "data.jld2"))
        @warn "No cached data found in $data_dir."
        return Vector{Dict{Symbol, Any}}()
    end

    data_file = joinpath(data_dir, "data.jld2")
    file = jldopen(data_file, "r")

    if !haskey(file, "activity")
        @warn "No activities found in cache."
        close(file)
        return Vector{Int}()
    end

    out = parse.(Int, keys(file["activity"]))
    close(file)

    @info "Loaded $(length(out)) cached activity IDs from $data_file."
    
    return out
end

"""
    get_cached_activity(id::Int; data_dir::String=DATA_DIR) -> Union{Dict{Symbol, Any}, Missing}

Load a cached activity from disk by ID.

# Arguments
- `id::Int`: Activity ID to retrieve from cache.
- `data_dir::String`: Directory for cached data (default: `DATA_DIR`).

# Returns
- `Dict{Symbol, Any}`: The full activity dict, or `missing` if not found.

This function does not contact the Strava API and only loads data previously cached by `get_activity`.
"""
function get_cached_activity(id::Int; data_dir::String=DATA_DIR)::Union{Dict{Symbol, Any}, Missing}
    data_file = joinpath(data_dir, "data.jld2")
    if !isfile(data_file)
        @warn "No cached data found in $data_dir."
        return missing
    end
    file = jldopen(data_file, "r")

    if !haskey(file, "activity/$id")
        close(file)
        @warn "Activity $id not found in cache."
        return missing
    end

    activity = Dict{Symbol, Any}()

    data = file["activity/$id"]
    for k in keys(data)
        activity[Symbol(k)] = data[k]
    end

    close(file)
    return activity
end

"""
    get_cached_activity_stream(id::Int, stream::Symbol; data_dir::String=DATA_DIR) -> Union{Vector, Missing}

Efficiently load a cached activity stream's data vector from disk by ID and stream name, without loading the full activity dict into memory.

# Arguments
- `id::Int`: Activity ID to retrieve from cache.
- `stream::Symbol`: The stream to retrieve (e.g., :distance_data).
- `data_dir::String`: Directory for cached data (default: `DATA_DIR`).

# Returns
- `Vector`: The requested stream's data vector, or `missing` if not found.

This function does not contact the Strava API and only loads the requested stream's data vector from the cache.
"""
function get_cached_activity_stream(id::Int, stream::Symbol; data_dir::String=DATA_DIR)::Union{Dict{Symbol, Any}, Missing}
    data_file = joinpath(data_dir, "data.jld2")
    if !isfile(data_file)
        @warn "No cached data found in $data_dir."
        return missing
    end
    file = jldopen(data_file, "r")
    if !haskey(file, "activity/$id")
        close(file)
        @warn "Activity $id not found in cache."
        return missing
    elseif !haskey(file, "activity/$id/$stream")
        close(file)
        @warn "Stream $stream not found in activity $id."
        return missing
    end
    stream_data = file["activity/$id/$stream"]
    close(file)
    return stream_data
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
function clear_data(; data_dir::String = DATA_DIR)::Nothing
    rm(joinpath(data_dir, "data.jld2"), force = true)
end

end  # module
