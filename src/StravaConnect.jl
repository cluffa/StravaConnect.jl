module StravaConnect

using HTTP
using URIs
using JSON
using DefaultApplication
using Serialization
using Dates

export User, refresh_if_needed!, setup_user, get_all_activities, get_activity

const DATA_DIR = "./data"

# conversions
const METER_TO_MILE = 0.000621371
const METER_TO_FEET = 3.28084
c2f(c) = (c * 9/5) + 32

mutable struct User
    client_id::String
    client_secret::String
    code::String
    access_token::String
    refresh_token::String
    expires_at::Int
    expires_in::Int
    athlete::Dict{String, Any}
end

User(client_id, client_secret) = User(client_id, client_secret, "", "", "", 0, 0, Dict{String, Any}())

function link_prompt(u::User, uri = "http://127.0.0.1:8081/authorization", browser_launch = true)::Nothing
    url = "https://www.strava.com/oauth/authorize?client_id=$(u.client_id)&redirect_uri=$uri&response_type=code&scope=activity:read_all,profile:read_all"
    
    if browser_launch
        DefaultApplication.open(url)
    else
        println("Authorize Access On Strava:")
        println(url)
    end

    return nothing
end

"""
    authorize!(u::User)::Nothing

authorizes new user `u` using strava login
"""
function authorize!(u::User)::Nothing
    link_prompt(u)
    
    server = HTTP.serve!(8081) do req
        params = queryparams(req)

        if haskey(params, "code")
            u.code = params["code"]
            @info "Updated user auth code, press enter to continue"
        else
            @info "Request with no code recieved, doing nothing"
            @info req
        end

        return HTTP.Response(200, "Auth code recieved, close window and return to terminal")
    end

    read(stdin, 1)
    close(server)
    
    # initial request for access_token using auth code
    response = try
        JSON.parse(String(HTTP.post(
            "https://www.strava.com/oauth/token",
            [],
            HTTP.Form(
                Dict(
                    "client_id" => u.client_id,
                    "client_secret" => u.client_secret,
                    "code" => u.code,
                    "grant_type" => "authorization_code"
                )
            )
        ).body))
    catch e
        @error "Failed to get authorization: $(e)"
        return nothing
    end

    # TODO only save id and other important info from profile
    u.athlete = response["athlete"]

    u.access_token = response["access_token"]
    u.refresh_token = response["refresh_token"]
    u.expires_at = response["expires_at"]
    u.expires_in = response["expires_in"]

    @info "new token expires in $(round(u.expires_in/86400; digits = 1)) days"

    return nothing
end

"""
    refresh!(u::User)::Nothing

refreshes user tokens
"""
function refresh!(u::User)::Nothing
    # request for updated access_token using refresh_token
    response = try
        JSON.parse(String(HTTP.post(
            "https://www.strava.com/oauth/token",
            [],
            HTTP.Form(
                Dict(
                    "client_id" => u.client_id,
                    "client_secret" => u.client_secret,
                    "refresh_token" => u.refresh_token,
                    "grant_type" => "refresh_token"
                )
            )
        ).body))
    catch e
        @error "Failed to refresh token: $(e)"
        return nothing
    end


    response = HTTP.post(
        "https://www.strava.com/oauth/token",
        [],
        HTTP.Form(
            Dict(
                "client_id" => u.client_id,
                "client_secret" => u.client_secret,
                "refresh_token" => u.refresh_token,
                "grant_type" => "refresh_token"
            )
        )
    ).body |> String |> JSON.parse

    u.access_token = response["access_token"]
    u.refresh_token = response["refresh_token"]
    u.expires_at = response["expires_at"]
    u.expires_in = response["expires_in"]

    @info "new token expires in $(round(u.expires_in/86400; digits = 2)) days"

    return nothing
end

"""
    refresh_if_needed!(u::User)::Nothing

refeshes user tokens if they are expired
"""
function refresh_if_needed!(u::User)::Nothing
    # if token expires in less than 5 min
    if (u.expires_at - time()) < 300
        @info "token refreshed"
        refresh!(u)
    else
        @info "token refresh not needed, valid for $(round((u.expires_at - time())/1440; digits = 2)) days"
    end

    return nothing
end



"""
    setup_user(token_file::AbstractString = ".tokens", force_auth::Bool = false)::User

Sets up user by loading tokens from file or authorizing new user
Requires STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET to be set in ENV
"""
function setup_user(token_file::AbstractString = ".tokens", force_auth::Bool = false)::User
    user = if isfile(token_file) && !force_auth
        Serialization.deserialize(token_file)
    else
        @assert haskey(ENV, "STRAVA_CLIENT_ID") "STRAVA_CLIENT_ID not set"
        @assert haskey(ENV, "STRAVA_CLIENT_SECRET") "STRAVA_CLIENT_SECRET not set"
        client_id = ENV["STRAVA_CLIENT_ID"]
        client_secret = ENV["STRAVA_CLIENT_SECRET"]
        
        new_user = User(client_id, client_secret)
        authorize!(new_user)

        new_user
    end

    refresh_if_needed!(user)
    Serialization.serialize(token_file, user)

    return user
end

"""
    get_all_activities(u::User; dataDir = DATA_DIR)::NamedTuple

gets all activities and returns NamedTuple, caches to file
"""
function get_all_activities(u::User; dataDir = DATA_DIR)::NamedTuple
    # check last time of cache
    if isfile(joinpath(dataDir, "activities.bin"))
        t_cache = floor(Int, mtime(joinpath(dataDir, "activities.bin")))
        activities = Serialization.deserialize(joinpath(dataDir, "activities.bin"))
    else
        t_cache = 0
        activities = (
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

    n_cache = length(activities.id)

    @info "$(n_cache) activities loaded from cache, getting activities after $(unix2datetime(t_cache))"

    page = 1
    while true
        response = try
            JSON.parse(String(HTTP.get(
                "https://www.strava.com/api/v3/athlete/activities?page=$page&per_page=$per_page&after=$t_cache",
                headers = Dict("Authorization" => "Bearer $(u.access_token)")
            ).body))
        catch e
            @error "Failed to get activities: $(e)"
            return nothing
        end
        
        
        for activity in response
            push!(activities.id, activity["id"])
            push!(activities.name, activity["name"])
            push!(activities.distance, activity["distance"])
            push!(activities.distance_mi, activity["distance"] * METER_TO_MILE)
            push!(activities.start_date_local, DateTime(activity["start_date_local"], dateformat"yyyy-mm-ddTHH:MM:SSZ"))
            push!(activities.elapsed_time, activity["elapsed_time"])
            push!(activities.sport_type, activity["sport_type"])
        end

        if length(response) < per_page
            break
        end

        page += 1
    end

    n_new = length(activities.id) - n_cache

    @info "$(n_new) new activities loaded, total $(length(activities.id)) activities"

    Serialization.serialize(joinpath(dataDir, "activities.bin"), activities)

    return activities
end

"""
    get_activity(id, u::User; dataDir = DATA_DIR)::NamedTuple

gets activity using id, returns NamedTuple of vectors
"""
function get_activity(id, u::User; dataDir = DATA_DIR)::NamedTuple
    temp_file = joinpath(dataDir, "activity_$id.bin")

    if isfile(temp_file)
        return Serialization.deserialize(temp_file)
    end

    streamkeys = ["time", "distance", "latlng", "altitude", "velocity_smooth", "heartrate", "cadence", "watts", "temp", "moving", "grade_smooth"]
    
    response = try
        JSON.parse(String(HTTP.get(
            "https://www.strava.com/api/v3/activities/$id/streams?keys=$(join(streamkeys, ","))&key_by_type=true",
            headers = Dict(
                "Authorization" => "Bearer $(u.access_token)",
                "accept" => "application/json"
                )
        ).body))
    catch e
        @error "Failed to get activity: $(e)"
        return nothing
    end

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

    for key in streamkeys
        if haskey(response, key) && !any(isnothing.(response[key]["data"]))
            if key == "latlng"
                append!(df[Symbol(key)], Tuple.(response[key]["data"]))
            else
                append!(df[Symbol(key)], response[key]["data"])
            end
        end
    end

    append!(df.distance_mi, df.distance * METER_TO_MILE)
    append!(df.altitude_ft, df.altitude * METER_TO_FEET)
    append!(df.temp_f, c2f.(df.temp))

    Serialization.serialize(temp_file, df)

    return df
end

end  # module
