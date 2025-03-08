module StravaConnect

using HTTP
using URIs
using JSON3
using Dates
using JLD2
using DataFrames

using PrecompileTools: @setup_workload, @compile_workload

include("oauth.jl")

export User, refresh_if_needed!, setup_user, get_activity_list, get_activity

const DATA_DIR = "./data"
const HIDE = true
const STREAMKEYS = ("time", "distance", "latlng", "altitude", "velocity_smooth", "heartrate", "cadence", "watts", "temp", "moving", "grade_smooth")

if !isdir(DATA_DIR)
    mkdir(DATA_DIR)
end

# conversions
const METER_TO_MILE = 0.000621371
const METER_TO_FEET = 3.28084
c2f(c::Number)::Number = (c * 9/5) + 32

mutable struct User
    access_token::String
    refresh_token::String
    expires_at::Int
    expires_in::Int
    athlete::Dict{String, Any}
end

User() = User("", "", 0, 0, Dict{String, Any}())

"""
    authorize!(u::User)::Nothing

authorizes new user `u` using strava login
"""
function authorize!(u::User)::Nothing
    token_info = oauth_flow()

    # TODO only save id and other important info from profile
    u.athlete = token_info.athlete
    u.access_token = token_info.access_token
    u.refresh_token = token_info.refresh_token
    u.expires_at = token_info.expires_at
    u.expires_in = token_info.expires_in

    HIDE || @info "new token expires in $(round(u.expires_in/86400; digits = 1)) days"

    return nothing
end

"""
    refresh!(u::User)::Nothing

refreshes user tokens
"""
function refresh!(u::User)::Nothing
    new_token = refresh_token(u.refresh_token)

    u.access_token = new_token.access_token
    u.refresh_token = new_token.refresh_token
    u.expires_at = new_token.expires_at
    u.expires_in = new_token.expires_in

    HIDE || @info "new token expires in $(round(u.expires_in/86400; digits = 2)) days"

    return nothing
end

"""
    refresh_if_needed!(u::User)::Nothing

refeshes user tokens if they are expired
"""
function refresh_if_needed!(u::User)::Nothing
    if u.expires_at < time()
        refresh!(u)
    end

    return nothing
end

"""
    setup_user(token_file::AbstractString = ".tokens", force_auth::Bool = false)::User

Sets up user by loading tokens from file or authorizing new user
Requires STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET to be set in ENV
"""
function setup_user()::User
    user = User()

    authorize!(user)
    
    return user
end

function setup_user(file::AbstractString)::User
    user = setup_user_from_file(file)

    if isnothing(user)
        user = setup_user()
        save_user(file, user)
    end

    return user
end

function save_user(user_file::AbstractString, u::User)::Nothing
    @assert lowercase(split(user_file, ".")[end]) == "json" "User file must be JSON format"

    open(user_file, "w") do io
        JSON3.pretty(io, u)
    end

    return nothing
end

function setup_user_from_file(user_file::AbstractString)::User
    @assert lowercase(split(user_file, ".")[end]) == "json" "User file must be JSON format"
    user = JSON3.read(user_file, User)

    HIDE || @info "athlete $(user.athlete["firstname"]) $(user.athlete["lastname"]) ($(user.athlete["id"])) loaded from file"

    refresh_if_needed!(user)

    return user
end

function activites_list_api(access_token::String, page::Int, per_page::Int, mtime::Int; dry_run::Bool = false)
    if dry_run
        return HTTP.Response(
            JSON3.read(read("activites_list_api.json", String))
        )
    else 
        resp = HTTP.get(
            "https://www.strava.com/api/v3/athlete/activities?page=$page&per_page=$per_page&after=$mtime",
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
            JSON3.read(read("activity_api.json", String))
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
            @error "Rate limit exceeded"
            return nothing
        elseif response.status != 200
            @error "Error getting activity"
            return nothing
        end

        return response
    end
end

"""
    get_activity_list(u::User; dataDir = DATA_DIR)::NamedTuple

gets all activities and returns NamedTuple, caches to file
"""
function get_activity_list(u::User; dataDir::String = DATA_DIR, dry_run = false)::NamedTuple
    isdir(dataDir) || mkdir(dataDir)

    file = jldopen(joinpath(dataDir, "data.jld2"), "a+", compress=true)
        
    if haskey(file, "activities") && haskey(file, "mtime")
        mtime = file["mtime"]
        df = file["activities"]
    else
        mtime = 0
        df = (
            id = Int64[],
            name = String[],
            distance = Float64[],
            distance_mi = Float64[],
            start_date_local = DateTime[],
            elapsed_time = Float64[],
            sport_type = String[]
        )
    end

    per_page = 200

    n_cache = length(df.id)

    HIDE || @info "$(n_cache) activities loaded from cache, getting activities after $(unix2datetime(mtime))"

    page = 1
    while true
        resp = activites_list_api(u.access_token, page, per_page, mtime; dry_run)

        body = JSON3.read(resp.body)
        
        for activity in body
            push!(df.id, activity["id"])
            push!(df.name, activity["name"])
            push!(df.distance, activity["distance"])
            push!(df.distance_mi, activity["distance"] * METER_TO_MILE)
            push!(df.start_date_local, DateTime(activity["start_date_local"], dateformat"yyyy-mm-ddTHH:MM:SSZ"))
            push!(df.elapsed_time, activity["elapsed_time"])
            push!(df.sport_type, activity["sport_type"])
        end

        if length(body) < per_page
            break
        end

        page += 1
    end

    n_new = length(df.id) - n_cache

    HIDE || @info "$(n_new) new activities loaded, total $(length(df.id)) activities"

    delete!(file, "activities")
    file["activities"] = df
    delete!(file, "mtime")
    file["mtime"] = Int(floor(time()))

    close(file)
    
    return df
end

"""
    get_activity(id, u::User; dataDir = DATA_DIR)::NamedTuple

gets activity using id, returns NamedTuple of vectors
"""
function get_activity(id::Int, u::User; dataDir::String = DATA_DIR, dry_run::Bool = false, force_update::Bool = false)::NamedTuple
    refresh_if_needed!(u)
    isdir(dataDir) || mkdir(dataDir)

    file = jldopen(joinpath(dataDir, "data.jld2"), "a+", compress=true)

    if haskey(file, "activity_$id") && !force_update
        out = file["activity_$id"]
        close(file)
        return out
    end

    response = activity_api(u.access_token, id; dry_run)

    body = JSON3.read(response.body)

    df = (
        time = Int64[],
        distance = Float64[],
        distance_mi = Float64[],
        latlng = Tuple{Float64, Float64}[],
        altitude = Float64[],
        altitude_ft = Float64[],
        velocity_smooth = Float64[],
        heartrate = Int64[],
        cadence = Int64[],
        watts = Float64[],
        temp = Int64[],
        temp_f = Float64[],
        moving = Bool[],
        grade_smooth = Float64[]
    )
    
    for key in STREAMKEYS
        if haskey(body, key) && !any(isnothing.(body[key]["data"]))
            if key == "latlng"
                append!(df[Symbol(key)], Tuple.(body[key]["data"]))
            else
                append!(df[Symbol(key)], body[key]["data"])
            end
        end
    end

    append!(df.distance_mi, df.distance * METER_TO_MILE)
    append!(df.altitude_ft, df.altitude * METER_TO_FEET)
    append!(df.temp_f, c2f.(df.temp))

    if haskey(file, "activity_$id")
        delete!(file, "activity_$id")
    end

    file["activity_$id"] = df

    close(file)

    return df
end

@setup_workload begin
    # Putting some things in `@setup_workload` instead of `@compile_workload` can reduce the size of the
    # precompile file and potentially make loading faster.

    @compile_workload begin
        # all calls in this block will be precompiled, regardless of whether
        # they belong to your package or not (on Julia 1.8 and higher)

        # u = setup_user("data/user.json");

        # activities = get_activity_list(u);

        # x = get_activity(activities.id[end], u);

    end
end

end  # module
