using HTTP
using JSON3

@assert haskey(ENV, "STRAVA_CLIENT_ID")
@assert haskey(ENV, "STRAVA_CLIENT_SECRET")

const STRAVA_CLIENT_ID = ENV["STRAVA_CLIENT_ID"]
const STRAVA_CLIENT_SECRET = ENV["STRAVA_CLIENT_SECRET"]
const STRAVA_AUTH_URL = "https://www.strava.com/oauth/authorize"
const STRAVA_TOKEN_URL = "https://www.strava.com/oauth/token"

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

    @info "new token expires in $(round(u.expires_in/86400; digits = 1)) days"

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

    @info "new token expires in $(round(u.expires_in/86400; digits = 2)) days"

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

    @info "athlete $(user.athlete["firstname"]) $(user.athlete["lastname"]) ($(user.athlete["id"])) loaded from file"

    refresh_if_needed!(user)

    return user
end

"""
    generate_authorization_url(redirect_uri::String)

Generate the OAuth authorization URL for Strava.
"""
function generate_authorization_url(redirect_uri::String)
    params = Dict(
        "client_id" => STRAVA_CLIENT_ID,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => "activity:read_all,profile:read_all"
    )
    return "$STRAVA_AUTH_URL?$(HTTP.escapeuri(params))"
end

"""
    exchange_code_for_token(code::String)

Exchange the authorization code for an access token.
"""
function exchange_code_for_token(code::String)
    response = HTTP.post(STRAVA_TOKEN_URL, 
        ["Content-Type" => "application/json"],
        JSON3.write(Dict(
            "client_id" => STRAVA_CLIENT_ID,
            "client_secret" => STRAVA_CLIENT_SECRET,
            "code" => code,
            "grant_type" => "authorization_code"
        ))
    )
    
    return JSON3.read(response.body)
end

"""
    refresh_token(refresh_token::String)

Get a new access token using a refresh token.
"""
function refresh_token(refresh_token::String)
    response = HTTP.post(STRAVA_TOKEN_URL,
        ["Content-Type" => "application/json"],
        JSON3.write(Dict(
            "client_id" => STRAVA_CLIENT_ID,
            "client_secret" => STRAVA_CLIENT_SECRET,
            "refresh_token" => refresh_token,
            "grant_type" => "refresh_token"
        ))
    )
    
    return JSON3.read(response.body)
end

# Example usage
function oauth_flow()
    # Generate authorization URL
    redirect_uri = "http://localhost:8000/callback"
    auth_url = generate_authorization_url(redirect_uri)
    println("Visit this URL to authorize: $auth_url")

    # After user authorizes, they'll get a code
    println("Enter the code from the redirect URL:")
    code = readline()

    # Exchange code for token
    token_info = exchange_code_for_token(code)
    println("Access token: $(token_info.access_token)")

    # Later, when token expires
    # new_token_info = refresh_token(token_info.refresh_token)
    # println("New access token: $(new_token_info.access_token)")

    return token_info
end