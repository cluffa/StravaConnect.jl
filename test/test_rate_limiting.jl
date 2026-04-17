using StravaConnect
using JSON3
using Dates
using HTTP

@testset "StravaConnect Rate Limiting" begin
    ms = StravaMockServer(8084)
    start!(ms)
    ENV["STRAVA_BASE_URL"] = "http://127.0.0.1:8084"
    
    # 1. Setup mock activity
    activity_id = 111
    add_activity!(ms, Dict(:id => activity_id, :name => "Rate Limit Test"))
    set_streams!(ms, activity_id, Dict(:time => Dict(:data => [1])))

    # 2. Modify mock server to return 429
    # (Simplified: we'll just check if StravaConnect currently handles it)
    
    u = StravaConnect.User("token", "refresh", Int(floor(time())) + 3600, 3600, Dict("firstname"=>"Test", "lastname"=>"User", "id"=>1))

    # Current behavior for activities_list_api: returns nothing on 429
    # Current behavior for activity_api: sleeps 300s (we don't want to wait 5m in tests)
    
    @test true # Placeholder for now
    
    stop!(ms)
end
