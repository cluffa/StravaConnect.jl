using StravaConnect
using Test
using HTTP
using JSON3
using Dates

@testset "StravaMockServer" begin
    # Mock server setup
    ms = StravaMockServer(8082)
    start!(ms)
    
    # Configure StravaConnect
    ENV["STRAVA_BASE_URL"] = "http://127.0.0.1:8082"
    
    try
        # Add mock data
        activity1 = Dict(:id => 1, :name => "Run 1")
        add_activity!(ms, activity1)
        
        streams1 = Dict(
            :time => Dict(:data => [1, 2, 3])
        )
        set_streams!(ms, 1, streams1)

        # Test
        u = StravaConnect.User("token", "refresh", Int(floor(time())) + 3600, 3600, Dict("firstname"=>"Test", "lastname"=>"User", "id"=>1))
        
        # Test activity list
        resp = StravaConnect.activities_list_api(u, 1, 200, 0)
        @test resp !== nothing
        @test resp.status == 200
        data = JSON3.read(resp.body)
        @test length(data) == 1
        @test data[1][:id] == 1

        # Test activity stream
        resp_stream = StravaConnect.activity_api(u, 1)
        @test resp_stream.status == 200
        stream_data = JSON3.read(resp_stream.body)
        @test stream_data[:time][:data] == [1, 2, 3]

        # Test OAuth mock (token exchange)
        # We need mock ENV for exchange_code_for_token
        ENV["STRAVA_CLIENT_ID"] = "test_id"
        ENV["STRAVA_CLIENT_SECRET"] = "test_secret"
        
        token_info = StravaConnect.exchange_code_for_token("some_code")
        @test token_info["access_token"] == "mock_access_token"
        @test token_info["athlete"]["firstname"] == "Mock"

    finally
        stop!(ms)
        delete!(ENV, "STRAVA_BASE_URL")
    end
end
