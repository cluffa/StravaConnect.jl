module StravaConnect

using HTTP
using URIs
using JSON
using DefaultApplication
using Serialization
using Dates
using Memoize

export User, refresh_if_needed!, setup_user, get_all_activities, get_activity

# conversions
METER_TO_MILE = 0.000621371
METER_TO_FEET = 3.28084
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
    
    # TODO Error handling
    # initial request for access_token using auth code
    response = JSON.parse(String(HTTP.post(
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
refreshes user tokens
"""
function refresh!(u::User)::Nothing
    # TODO Error handling
    # request for updated access_token using refresh_token
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

    @info "new token expires in $(round(u.expires_in/86400; digits = 1)) days"

    return nothing
end

"""
refeshes user tokens if they are expired
"""
function refresh_if_needed!(u::User)::Nothing
    # if token expires in less than 5 min
    if (u.expires_at - time()) < 300
        @info "token refreshed"
        refresh!(u)
    else
        @info "token refresh not needed"
    end

    return nothing
end


"""
Sets up a new user using client id and secret from a file named .secret
this file contains client id on line 1 and client secret on line 2 

or loads user tokens from .tokens if present
"""
function setup_user(token_file::AbstractString = ".tokens", secret_file::AbstractString = ".secret")::User
    user = if isfile(token_file)
        Serialization.deserialize(token_file)
    else
        @assert isfile(secret_file) "Error: Need to create .secret file with client id and client secret (on lines 1 & 2)"
        user_id, user_secret = strip.(readlines(secret_file))
        new_user = User(user_id, user_secret)
        authorize!(new_user)

        new_user
    end

    refresh_if_needed!(user)
    Serialization.serialize(token_file, user)

    return user
end

"""
gets all activities and returns dataframe
"""
@memoize function get_all_activities(u::User)::NamedTuple
    per_page = 200
    activities = (
        id = Int64[],
        name = String[],
        distance = Float64[],
        distance_mi = Float64[],
        start_date_local = DateTime[],
        elapsed_time = Float64[],
        sport_type = String[]
        )
    page = 1
    while true
        # TODO Error handling
        response = JSON.parse(String(HTTP.get(
                "https://www.strava.com/api/v3/athlete/activities?page=$page&per_page=$per_page",
                headers = Dict("Authorization" => "Bearer $(u.access_token)")
            ).body))
        
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

    return activities
end


@memoize function get_activity(id, u::User)::NamedTuple
    streamkeys = ["time", "distance", "latlng", "altitude", "velocity_smooth", "heartrate", "cadence", "watts", "temp", "moving", "grade_smooth"]
    # TODO error handling
    response = JSON.parse(String(HTTP.get(
                    "https://www.strava.com/api/v3/activities/$id/streams?keys=$(join(streamkeys, ","))&key_by_type=true",
                    headers = Dict(
                        "Authorization" => "Bearer $(u.access_token)",
                        "accept" => "application/json"
                        )
                ).body))

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
        if haskey(response, key)
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
    
    return df
end

end  # module
