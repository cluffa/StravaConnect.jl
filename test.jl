using StravaConnect
using HTTP
using JSON
using DataFrames

user = setup_user()

url = "https://www.strava.com/api/v3/"

begin
    per_page = 200
    activities = []
    page = 1
    while true
        response = HTTP.get(
            "https://www.strava.com/api/v3/athlete/activities?page=$page&per_page=$per_page",
            headers = Dict("Authorization:" => "Bearer $(user.access_token)")
            ).body |>
            String |>
            JSON.parse
        
        append!(activities, response)

        if length(response) < per_page
            break
        end

        page += 1
    end

end

response[1] |> print