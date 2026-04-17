module StravaConnect

using HTTP
using URIs
using JSON3
using Dates
using JLD2
using SQLite
using PrecompileTools: @setup_workload, @compile_workload

export setup_user, get_or_setup_user,
    get_activity_list, get_cached_activity_list, get_cached_activity_ids,
    get_activity, get_activity_stream, get_cached_activity, get_cached_activity_stream,
    reduce_subdicts!, fill_dicts!,
    StravaMockServer, start!, stop!, add_activity!, set_streams!

const DATA_DIR = get(ENV, "STRAVA_DATA_DIR", tempdir())
strava_base_url() = get(ENV, "STRAVA_BASE_URL", "https://www.strava.com")

mutable struct RateLimit
    short_term_limit::Int    # 15 min
    short_term_usage::Int
    long_term_limit::Int     # daily
    long_term_usage::Int
end

RateLimit() = RateLimit(100, 0, 1000, 0) # Placeholder defaults

const GLOBAL_RATE_LIMIT = Ref(RateLimit())

function update_rate_limit!(resp::HTTP.Response)
    limit_header = HTTP.header(resp, "X-RateLimit-Limit")
    usage_header = HTTP.header(resp, "X-RateLimit-Usage")
    
    if !isempty(limit_header) && !isempty(usage_header)
        try
            limits = parse.(Int, split(limit_header, ","))
            usage = parse.(Int, split(usage_header, ","))
            
            if length(limits) == 2 && length(usage) == 2
                GLOBAL_RATE_LIMIT[].short_term_limit = limits[1]
                GLOBAL_RATE_LIMIT[].short_term_usage = usage[1]
                GLOBAL_RATE_LIMIT[].long_term_limit = limits[2]
                GLOBAL_RATE_LIMIT[].long_term_usage = usage[2]
            end
        catch e
            @warn "Failed to parse RateLimit headers: $e"
        end
    end
end

function check_rate_limit()
    rl = GLOBAL_RATE_LIMIT[]
    short_remaining = rl.short_term_limit - rl.short_term_usage
    long_remaining = rl.long_term_limit - rl.long_term_usage
    return (short=short_remaining, long=long_remaining)
end

function wait_if_needed()
    rem = check_rate_limit()
    if rem.short <= 1
        @warn "Rate limit nearly reached ($(rem.short) remaining in 15min). Waiting 60s..."
        sleep(60)
    elseif rem.long <= 1
        error("Daily rate limit reached. Aborting.")
    end
end

const HIDE = true
const STREAMKEYS = ("time", "distance", "latlng", "altitude", "velocity_smooth", "heartrate", "cadence", "watts", "temp", "moving", "grade_smooth")

const STREAM_TYPES = Dict{Symbol, Type}(
    :time => Int, # always 64-bit
    :distance => Float32,
    :latlng => Tuple{Float32, Float32},
    :altitude => Float32,
    :velocity_smooth => Float32,
    :heartrate => Float32,
    :cadence => Float32,
    :watts => Float32,
    :temp => Float32,
    :moving => Bool,
    :grade_smooth => Float32,
)

# conversions
const METER_TO_MILE = 0.000621371
const METER_TO_FEET = 3.28084
c2f(c::Number)::Number = (c * 9/5) + 32

include("oauth.jl")
include("test_server/mock_server.jl")
include("storage.jl")
include("migrate.jl")

export StravaMockServer, start!, stop!, add_activity!, set_streams!, migrate_jld2_to_sqlite

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
    wait_if_needed()
    
    resp = HTTP.get(
        "$(strava_base_url())/api/v3/athlete/activities?page=$page&per_page=$per_page&after=$after",
        headers = Dict("Authorization" => "Bearer $(u.access_token)"),
        status_exception = false  # Don't throw an exception for non-200 responses
    )

    update_rate_limit!(resp)

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
    if wait_on_rate_limit
        wait_if_needed()
    end

    response = HTTP.get(
        "$(strava_base_url())/api/v3/activities/$id/streams?keys=$(join(STREAMKEYS, ","))&key_by_type=true",
        headers = Dict(
            "Authorization" => "Bearer $(u.access_token)",
            "accept" => "application/json"
        ),
        status_exception = false  # Don't throw an exception for non-200 responses
    )

    update_rate_limit!(response)

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

See also: [`get_activity_list`](@ref) for a version that does not require a `User` argument.
"""
function get_activity_list(u::User; data_dir::String = DATA_DIR, force_update::Bool = false)::Vector{Dict{Symbol, Any}}
    refresh_if_needed!(u)
    db = init_db(data_dir)

    try
        T = Vector{Dict{Symbol, Union{Dict{Symbol, Any}, Any}}}

        last_check_mtime = 0
        list = Dict{Symbol, Any}[]
        
        if !force_update
            last_check_mtime = get_cached_mtime(db)
            list = get_cached_metadata_all(db)
            @info "$(length(list)) activities loaded from SQLite cache"
        else
            @info "Force update: fetching all activities from API."
        end

        # Throttle: Only check API if last check was > 5 minutes ago (unless force_update)
        if last_check_mtime < time() - 300 || force_update
            # Calculate 'after' based on latest activity start date in DB
            max_start = get_max_start_date(db)
            
            # Use a 1-day buffer (86400s) to catch activities that started in the past
            # but were only uploaded/synced to Strava recently.
            after_time = max(0, max_start - 86400)
            
            if force_update
                after_time = 0
            end

            @info "Checking for new activities after $(unix2datetime(after_time))"
    
            per_page = 200
            page = 1
            new_count = 0
            existing_ids = Set(Int(act[:id]) for act in list)
            
            while true
                resp = activities_list_api(u, page, per_page, after_time)

                if isnothing(resp)
                    break
                end

                data = JSON3.read(resp.body, T)
                
                if length(data) == 0
                    break
                end

                for act in data
                    id = Int(act[:id])
                    save_activity_metadata!(db, id, act, Int(floor(time())))
                    if id ∉ existing_ids
                        push!(list, act)
                        push!(existing_ids, id)
                        new_count += 1
                    end
                end
                
                if length(data) < per_page
                    break
                end

                page += 1
            end
            
            set_cached_mtime!(db, Int(floor(time())))
            @info "$new_count new activities added to cache, total $(length(list)) activities"
        end

        return list
    finally
        close(db)
    end
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

See also: [`get_activity`](@ref) for a version that does not require a `User` argument.
"""
function get_activity(id::Int, u::User; data_dir::String = DATA_DIR, force_update::Bool = false, verbose::Bool = false, wait_on_rate_limit::Bool = true)::Dict{Symbol, Any}
    refresh_if_needed!(u)
    db = init_db(data_dir)

    try
        T = Dict{Symbol, Dict{Symbol, Any}}

        activity = missing
        if !force_update
            if has_cached_streams(db, id)
                activity = get_cached_activity_db(db, id)
            end
        end
        
        if !ismissing(activity)
            if verbose
                @info "Loaded activity $id from SQLite cache"
            end
            return activity
        else
            response = activity_api(u, id; wait_on_rate_limit=wait_on_rate_limit)
            if response.status == 200
                activity_data = JSON3.read(response.body, T)
                activity = Dict{Symbol, Any}()

                for k in keys(activity_data)
                    stream = activity_data[k]
                    ST = STREAM_TYPES[k]
                    if any(isnothing.(stream[:data])) && ST == Float32
                        stream[:data] = ST[isnothing(x) ? NaN32 : ST(x) for x in stream[:data]]
                    else
                        stream[:data] = ST[ST(x) for x in stream[:data]]  # convert the data to the correct type
                    end
                    
                    save_stream!(db, id, string(k), Dict(stream))
                    activity[k] = stream
                end

                if verbose
                    @info "Fetched activity $id from API and cached in SQLite"
                end
                return activity
            elseif  response.status != 200
                @warn "Error getting activity $id: $(response.status) $(response.body)"
                return Dict{Symbol, Any}()  # return an empty dict if the request failed
            end
        end
    finally
        close(db)
    end

    return Dict{Symbol, Any}()
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
    db_path = get_db_path(data_dir)
    if !isfile(db_path)
        @warn "No SQLite database found at $db_path."
        return Vector{Dict{Symbol, Any}}()
    end

    db = SQLite.DB(db_path)
    try
        out = get_cached_metadata_all(db)
        @info "Loaded cached activity list from $db_path with $(length(out)) activities."
        return out
    finally
        close(db)
    end
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
    db_path = get_db_path(data_dir)
    if !isfile(db_path)
        @warn "No SQLite database found at $db_path."
        return Vector{Int}()
    end

    db = SQLite.DB(db_path)
    try
        out = get_cached_ids_db(db)
        @info "Loaded $(length(out)) cached activity IDs from $db_path."
        return out
    finally
        close(db)
    end
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
    db_path = get_db_path(data_dir)
    if !isfile(db_path)
        return missing
    end
    db = SQLite.DB(db_path)
    try
        return get_cached_activity_db(db, id)
    finally
        close(db)
    end
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
    db_path = get_db_path(data_dir)
    if !isfile(db_path)
        return missing
    end
    db = SQLite.DB(db_path)
    try
        return get_cached_stream_db(db, id, string(stream))
    finally
        close(db)
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
    rm(get_db_path(data_dir), force = true)
end

end  # module
