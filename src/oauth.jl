using HTTP
using JSON3

@assert haskey(ENV, "STRAVA_CLIENT_ID")
@assert haskey(ENV, "STRAVA_CLIENT_SECRET")

const STRAVA_CLIENT_ID = ENV["STRAVA_CLIENT_ID"]
const STRAVA_CLIENT_SECRET = ENV["STRAVA_CLIENT_SECRET"]
const STRAVA_AUTH_URL = "https://www.strava.com/oauth/authorize"
const STRAVA_TOKEN_URL = "https://www.strava.com/oauth/token"

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