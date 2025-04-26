using Pkg; Pkg.activate(@__DIR__); Pkg.instantiate()

using Revise
using WGLMakie
using WGLMakie.Makie
using StravaConnect

@info pathof(StravaConnect)

meter_to_mile(x::Real)::Real = x / 1609.34
mile_to_meter(x::Real)::Real = x * 1609.34

"""
    calculate_fastest_split(time_data::Vector{Int}, distance_data::Vector{Float64}, target_distance::Float64) -> Union{Int, Missing}

Calculates the fastest split time in seconds for a given distance in meters.

# Arguments
- `time_data::Vector{Int}`: Vector of timestamps in seconds.
- `distance_data::Vector{Float64}`: Vector of distances in meters.
- `target_distance::Float64`: The desired distance for the split in meters.

# Returns
- `Union{Int, Missing}`: The fastest split time in seconds for the specified distance. Returns `missing` if no split of that distance is found.
"""
function calculate_fastest_split(time_data::Vector{Int}, distance_data::Vector{Float64}, target_distance::Float64)::Union{Int, Missing}
    n = length(time_data) # Assuming time and distance data have the same length
    # Early exit if data is empty or target distance is non-positive
    if n == 0 || target_distance <= 0.0
        return missing
    end

    i = 1 # start index
    j = 1 # end index
    fastest_split = typemax(Int)
    min_split_found = false # Flag to track if any valid split was found

    @inbounds while j <= n && i <= n
        current_distance = distance_data[j] - distance_data[i]

        if current_distance >= target_distance
            # Potential split found
            split_time = time_data[j] - time_data[i]
            if split_time < fastest_split
                fastest_split = split_time
                min_split_found = true
            end
            # Try to shorten the window from the left
            i += 1
            # Ensure i doesn't skip past j unnecessarily after incrementing
            if i > j && j <= n
                 j = i # Reset j if i overtook it
            end
        else
            # Expand the window to the right
            j += 1
        end
    end

    return min_split_found ? fastest_split : missing
end

get_or_setup_user();

list = get_activity_list() |> reduce_subdicts! |> fill_dicts!;
cached_ids = get_cached_activity_ids()
filter!(list) do a
    contains(lowercase(a[:type]), "run") &&
        a[:id] ∈ cached_ids
end;

distances = Dict{Int64, Float64}(l[:id] => l[:distance] for l in list)

@time actDict = Dict(
    id => Dict{Symbol, Any}(
        :distance_data => get_cached_activity_stream(id, :distance)[:data],
        :time_data => get_cached_activity_stream(id, :time)[:data]
        ) for id in getindex.(list, :id)
    )

# scales activities with corrected distances
for id in getindex.(list, :id)
    if haskey(actDict[id], :distance_data)
        scale = distances[id] / actDict[id][:distance_data][end]
        actDict[id][:scale] = scale
        if scale != 1.0
            actDict[id][:distance_data] .*= scale
        end
    end
end

acts = values(actDict) |> collect

function floor_to_factor(x::Real, factor::Real)
    return floor(x / factor) * factor
end

race_distances = [3.1, 6.2, 13.1, 26.2, 31.1, 50.0, 100.0]
max_distance = distances |> values |> maximum |> meter_to_mile
filter!(race_distances) do d
    d <= max_distance
end

res = 0.5
rng = vcat(race_distances, 1:res:floor_to_factor(max_distance, res))
sort!(rng)
unique!(rng)
target_distances_meters = mile_to_meter.(rng) # Pre-calculate target distances in meters

paces = fill!(Matrix{Union{Missing, Float64}}(undef, length(rng), length(list)), missing)
times = fill!(Matrix{Union{Missing, Int}}(undef, length(rng), length(list)), missing) # Use Int for time

ids = getindex.(list, :id)

@time @inbounds Threads.@threads for (col_idx, id) in enumerate(ids) |> collect
    act = actDict[id]

    time_data = act[:time_data] isa Vector{Int} ? act[:time_data] : Vector{Int}(act[:time_data])
    distance_data = act[:distance_data] isa Vector{Float64} ? act[:distance_data] : Vector{Float64}(act[:distance_data])
    times[:, col_idx] .= calculate_fastest_split.((time_data,), (distance_data,), target_distances_meters)
end

paces .= ifelse.(ismissing.(times), missing, (times ./ 60.0) ./ rng)

max_paces = minimum.(skipmissing.(eachrow(paces)), init = Inf)
replace!(max_paces, Inf => missing)

# plot rng, max_paces

function pace_to_str(pace::Real)::String
    pace_min = floor(pace) |> Int
    pace_sec = floor((pace - pace_min) * 60) |> Int
    return string(pace_min, ":", lpad(pace_sec, 2, "0"))
end

pace_to_str(paces::Vector)::Vector{String} = pace_to_str.(paces)

begin
    fig = Figure()
    ax = Axis(
        fig[1, 1],
        title = "Fastest splits",
        xlabel = "Distance (miles)",
        ylabel = "Pace (min/mile)",
        xscale = log,
        xticks = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 15, 20, 25, 30, 50, 100],
        ytickformat = pace_to_str,
    )

    # xlims!(ax, 0, maximum(rng))
    ylims!(ax, minimum(max_paces), maximum(max_paces))
    

    lines!(
        ax, rng, max_paces, color = :black, label = "Fastest split",
    )

    # vlines!(ax, race_distances, 0, maximum(max_paces), color = :lightgreen, label = "5k")

    for (i, id) in enumerate(ids)
        act = actDict[id]
        if haskey(act, :time_data) && haskey(act, :distance_data)
            valid_paces = skipmissing(paces[:, i]) |> collect

            is_fastest = any(skipmissing(paces[:, i] .== max_paces))
            
            lines!(ax, rng[eachindex(valid_paces)], valid_paces,
                color = is_fastest ? :red : :blue,
                label = "Activity $(id)",
                alpha = is_fastest ? 0.5 : 0.25,
                linewidth = is_fastest ? 0.5 : 0.25,
            )
        end
    end
end; display(fig)

save("examples/fastest_splits.png", fig)

for dist in rng
    idx = findfirst(==(dist), rng)
    # Need to handle potential missing values when finding the minimum pace
    row_paces = paces[idx, :]
    valid_indices = findall(!ismissing, row_paces)
    if isempty(valid_indices)
        println("$(dist) miles: No valid pace found.")
        continue
    end
    min_pace, rel_idx = findmin(@view row_paces[valid_indices])
    idx2 = valid_indices[rel_idx]


    id = ids[idx2]
    details = filter(list) do a
        a[:id] == id
    end

    details = length(details) > 0 ? first(details) : Dict(:id => id, :name => "Unknown")

    pace_str = pace_to_str(min_pace)

    println("$(dist) miles: $(pace_str) in activity $(details[:name]) https://www.strava.com/activities/$(details[:id])")
end