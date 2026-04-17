using StravaConnect
using HTTP
using JSON3
using Dates

"""
    StravaMockServer

A simple mock server for emulating the Strava API.
"""
mutable struct StravaMockServer
    port::Int
    server::Union{HTTP.Servers.Server, Nothing}
    activities::Vector{Dict}
    streams::Dict{String, Dict}

    function StravaMockServer(port::Int = 8081)
        new(port, nothing, [], Dict())
    end
end

function start!(s::StravaMockServer)
    s.server = HTTP.serve!(s.port) do request
        headers = [
            "Content-Type" => "application/json",
            "X-RateLimit-Limit" => "100,1000",
            "X-RateLimit-Usage" => "10,100"
        ]
        
        if occursin("/api/v3/athlete/activities", request.target)
            uri = URIs.URI(request.target)
            query = URIs.queryparams(uri)
            after_val = parse(Int, get(query, "after", "0"))
            
            filtered_activities = filter(s.activities) do act
                sd = get(act, :start_date, "1970-01-01T00:00:00Z")
                unix_sd = Int(floor(datetime2unix(DateTime(sd[1:19]))))
                return unix_sd > after_val
            end
            return HTTP.Response(200, headers, JSON3.write(filtered_activities))
        elseif (m = match(r"/api/v3/activities/(\d+)/streams", request.target)) !== nothing
            id = m.captures[1]
            if haskey(s.streams, id)
                return HTTP.Response(200, headers, JSON3.write(s.streams[id]))
            else
                return HTTP.Response(404, headers, JSON3.write(Dict(:message => "Not Found")))
            end
        elseif occursin("/oauth/token", request.target)
            return HTTP.Response(200, headers, JSON3.write(Dict(
                :access_token => "mock_access_token",
                :refresh_token => "mock_refresh_token",
                :expires_at => Int(floor(time())) + 3600,
                :expires_in => 3600,
                :athlete => Dict(:id => 1, :firstname => "Mock", :lastname => "User")
            )))
        end
        return HTTP.Response(404, headers, JSON3.write(Dict(:message => "Not Found")))
    end
    @info "Strava mock server started on port $(s.port)"
    return s
end

function stop!(s::StravaMockServer)
    if s.server !== nothing
        close(s.server)
        s.server = nothing
        @info "Strava mock server stopped"
    end
end

function add_activity!(s::StravaMockServer, activity::Dict)
    push!(s.activities, activity)
end

function set_streams!(s::StravaMockServer, activity_id::Int, streams::Dict)
    s.streams[string(activity_id)] = streams
end
