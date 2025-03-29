using HTTP
using JSON3

const STRAVA_AUTH_URL = "https://www.strava.com/oauth/authorize"
const STRAVA_TOKEN_URL = "https://www.strava.com/oauth/token"
# const DATA_DIR = get(ENV, "STRAVA_DATA_DIR", tempdir()) # already defined in StravaConnect.jl

mutable struct User
    access_token::String
    refresh_token::String
    expires_at::Int
    expires_in::Int
    athlete::Dict{String, Any}
end

User() = User("", "", 0, 0, Dict{String, Any}())

"""
    authorize!(u::User) -> Nothing

Authorize a new user using the Strava OAuth flow.

# Arguments
- `u::User`: User struct to store authorization information
"""
function authorize!(u::User)::Nothing
    token_info = oauth_flow()
    update_user!(u, token_info)
    return nothing
end

function update_user!(u::User, token_info::Dict{String, Any})::Nothing
    if haskey(token_info, "athlete")
        u.athlete = token_info["athlete"]
    end

    u.access_token = token_info["access_token"]
    u.refresh_token = token_info["refresh_token"]
    u.expires_at = token_info["expires_at"]
    u.expires_in = token_info["expires_in"]

    @info "new token expires in $(round(u.expires_in/86400; digits = 1)) days"
end

"""
    refresh!(u::User) -> Nothing

Refresh the access token for a user using their refresh token.

# Arguments
- `u::User`: User struct containing the refresh token
"""
function refresh!(u::User)::Nothing
    new_token = refresh_token(u.refresh_token)
    update_user!(u, new_token)
    return nothing
end

"""
    refresh_if_needed!(u::User) -> Nothing

Check if the user's token needs refreshing and refresh if expired.

# Arguments
- `u::User`: User struct to check and potentially refresh
"""
function refresh_if_needed!(u::User)::Nothing
    if u.expires_at < time()
        refresh!(u)
    end

    return nothing
end

"""
    setup_user(; force_reauthenticate::Bool = false) -> User

Load user from `DATA_DIR` or create a new user if no file exists or if reauthentication is forced.

# Arguments
- `force_reauthenticate::Bool`: If true, forces reauthentication even if a user file exists (default: false).

# Returns
- `User`: Loaded or newly created user struct
"""
function setup_user(; force_reauthenticate::Bool = false)::User
    user_file = joinpath(DATA_DIR, "user.json")
    if !force_reauthenticate && isfile(user_file)
        user = setup_user_from_file(user_file)
    else
        user = User()
        authorize!(user)
        save_user(user_file, user)
    end

    return user
end

"""
    save_user(user_file::AbstractString, u::User) -> Nothing

Save user data to a JSON file.

# Arguments
- `user_file::AbstractString`: Path to JSON file
- `u::User`: User struct to save
"""
function save_user(user_file::AbstractString, u::User)::Nothing
    @assert lowercase(split(user_file, ".")[end]) == "json" "User file must be JSON format"

    if !isdir(dirname(user_file))
        mkpath(dirname(user_file))
    end

    open(user_file, "w") do io
        JSON3.pretty(io, u)
    end

    return nothing
end

"""
    setup_user_from_file(user_file::AbstractString) -> User

Load user from a JSON file and refresh token if needed.

# Arguments
- `user_file::AbstractString`: Path to JSON file containing user data

# Returns
- `User`: Loaded user struct
"""
function setup_user_from_file(user_file::AbstractString)::User
    @assert lowercase(split(user_file, ".")[end]) == "json" "User file must be JSON format"
    user = JSON3.read(user_file, User)

    @info "athlete $(user.athlete["firstname"]) $(user.athlete["lastname"]) ($(user.athlete["id"])) loaded from file"

    refresh_if_needed!(user)

    return user
end

"""
    generate_authorization_url(redirect_uri::String) -> String

Generate the OAuth authorization URL for Strava.

# Arguments
- `redirect_uri::String`: URI where Strava will redirect after authorization

# Returns
- `String`: Complete authorization URL
"""
function generate_authorization_url(redirect_uri::String)::String
    params = Dict(
        "client_id" => ENV["STRAVA_CLIENT_ID"],
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => "activity:read_all,profile:read_all"
    )
    return "$STRAVA_AUTH_URL?$(HTTP.escapeuri(params))"
end

"""
    exchange_code_for_token(code::String) -> JSON3.Object

Exchange authorization code for access token.

# Arguments
- `code::String`: Authorization code from Strava redirect

# Returns
- `JSON3.Object`: Token response containing access_token, refresh_token, and expiration
"""
function exchange_code_for_token(code::String)::Dict{String, Any}
    response = HTTP.post(STRAVA_TOKEN_URL, 
        ["Content-Type" => "application/json"],
        JSON3.write(Dict(
            "client_id" => ENV["STRAVA_CLIENT_ID"],
            "client_secret" => ENV["STRAVA_CLIENT_SECRET"],
            "code" => code,
            "grant_type" => "authorization_code"
        ))
    )
    
    return JSON3.read(response.body, Dict{String, Any})
end

"""
    refresh_token(refresh_token::String) -> JSON3.Object

Get new access token using refresh token.

# Arguments
- `refresh_token::String`: Valid refresh token

# Returns
- `JSON3.Object`: Token response containing new access_token and refresh_token
"""
function refresh_token(refresh_token::String)::Dict{String, Any}
    response = HTTP.post(STRAVA_TOKEN_URL,
        ["Content-Type" => "application/json"],
        JSON3.write(Dict(
            "client_id" => ENV["STRAVA_CLIENT_ID"],
            "client_secret" => ENV["STRAVA_CLIENT_SECRET"],
            "refresh_token" => refresh_token,
            "grant_type" => "refresh_token"
        ))
    )
    
    return JSON3.read(response.body, Dict{String, Any})
end

# Example usage
function oauth_flow()::Dict{String, Any}
    # Generate authorization URL
    redirect_uri = "http://localhost:8000/callback"
    auth_url = generate_authorization_url(redirect_uri)
    println("Visit this URL to authorize: $auth_url")

    # After user authorizes, they'll get a code
    println("Enter the code from the redirect URL:")
    code = readline()

    # Exchange code for token
    token_info = exchange_code_for_token(code)
    println("Access token: $(token_info["access_token"])")

    # Later, when token expires
    # new_token_info = refresh_token(token_info.refresh_token)
    # println("New access token: $(new_token_info["access_token"])")

    return token_info
end