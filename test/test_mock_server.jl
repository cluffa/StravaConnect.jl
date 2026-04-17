using StravaConnect
using Test
using HTTP
using JSON3
using Dates

@testset "StravaMockServer and API" begin
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
            :time => Dict(:data => [1, 2, 3]),
            :distance => Dict(:data => [10.0, 20.0, 30.0])
        )
        set_streams!(ms, 1, streams1)

        # Test
        u = StravaConnect.User("token", "refresh", Int(floor(time())) + 3600, 3600, Dict("firstname"=>"Test", "lastname"=>"User", "id"=>1))
        
        @testset "Direct API Calls" begin
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
        end

        @testset "Rate Limit Tracking" begin
            # Headers from mock server are "100,1000" and "10,100"
            @test StravaConnect.GLOBAL_RATE_LIMIT[].short_term_limit == 100
            @test StravaConnect.GLOBAL_RATE_LIMIT[].short_term_usage == 10
            @test StravaConnect.GLOBAL_RATE_LIMIT[].long_term_limit == 1000
            @test StravaConnect.GLOBAL_RATE_LIMIT[].long_term_usage == 100
        end

        @testset "OAuth mock" begin
            ENV["STRAVA_CLIENT_ID"] = "test_id"
            ENV["STRAVA_CLIENT_SECRET"] = "test_secret"
            
            token_info = StravaConnect.exchange_code_for_token("some_code")
            @test token_info["access_token"] == "mock_access_token"
            @test token_info["athlete"]["firstname"] == "Mock"

            new_token = StravaConnect.refresh_token("some_refresh_token")
            @test new_token["access_token"] == "mock_access_token"
        end

        @testset "Data Manipulation" begin
            d = Dict{Symbol, Any}(:a => Dict(:b => 1))
            reduce_subdicts!(d)
            @test haskey(d, :a_b)
            @test d[:a_b] == 1

            d1 = Dict{Symbol, Any}(:x => 1)
            d2 = Dict{Symbol, Any}(:y => 2)
            fill_dicts!([d1, d2])
            @test haskey(d1, :y)
            @test isnothing(d1[:y])
            @test haskey(d2, :x)
            @test isnothing(d2[:x])
        end

        @testset "High-level Caching API" begin
            mktempdir() do data_dir
                # Test get_activity_list with cache
                list = get_activity_list(u; data_dir=data_dir)
                @test length(list) == 1
                @test list[1][:id] == 1
                
                # Verify file exists
                @test isfile(joinpath(data_dir, "data.jld2"))
                
                # Test get_cached_activity_list
                cached_list = get_cached_activity_list(data_dir)
                @test length(cached_list) == 1
                
                # Test get_activity (detailed, with streams)
                activity = get_activity(1, u; data_dir=data_dir)
                @test haskey(activity, :time)
                @test activity[:time][:data] == [1, 2, 3]
                
                # Test get_cached_activity_ids
                ids = get_cached_activity_ids(data_dir)
                @test ids == [1]
                
                # Test get_cached_activity
                cached_activity = get_cached_activity(1; data_dir=data_dir)
                @test cached_activity[:time][:data] == [1, 2, 3]
                
                # Test get_cached_activity_stream
                stream = get_cached_activity_stream(1, :distance; data_dir=data_dir)
                @test stream[:data] == [10.0, 20.0, 30.0]

                # Test clear_data
                StravaConnect.clear_data(; data_dir=data_dir)
                @test !isfile(joinpath(data_dir, "data.jld2"))
            end
        end

    finally
        stop!(ms)
        delete!(ENV, "STRAVA_BASE_URL")
    end
end
