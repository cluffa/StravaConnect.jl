using StravaConnect
using Test
using HTTP
using JSON3
using Dates

@testset "StravaConnect.jl" begin
    include("test_mock_server.jl")
    
    # Original tests (or placeholders)
    # Note: get_or_setup_user() requires interactive input or a valid user.json
    # In a CI/automated environment, we should use the mock server.
end
