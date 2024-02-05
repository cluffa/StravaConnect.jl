module StravaConnect

using HTTP
using URIs
using JSON
using DefaultApplication
using Serialization

export User, refresh_if_needed!, setup_user

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

function link_prompt(u::User, uri = "http://127.0.0.1:8081/authorization", browser_launch = true)
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
function authorize!(u::User)
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
    response = HTTP.post(
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
    ).body |> String |> JSON.parse

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
function refresh!(u::User)
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
function refresh_if_needed!(u::User)
    if time() > u.expires_at
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
function setup_user(token_file = ".tokens", secret_file = ".secret")
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

end  # module
