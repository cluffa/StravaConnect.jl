using Pkg; Pkg.activate(@__DIR__); Pkg.instantiate()

using Revise
using Makie
# using WGLMakie
using CairoMakie
using StravaConnect
using Printf

@info pathof(StravaConnect)

meter_to_mile(x) = x / 1609.34
mile_to_meter(x) = x * 1609.34

"""
    calculate_fastest_split!(dest::AbstractVector{Int}, time_data::Vector{Int}, distance_data::Vector{Float64}, target_distances::Vector{Float64})

Calculates the fastest split time in seconds for given distances in meters and stores them in `dest`.

# Arguments
- `dest::AbstractVector{Int}`: Vector to store the calculated fastest split times in seconds.
- `time_data::Vector{Int}`: Vector of timestamps in seconds.
- `distance_data::Vector{Float64}`: Vector of distances in meters.
- `target_distances::Vector{Float64}`: Vector of desired distances for the splits in meters.

# Returns
- `Nothing`: The function modifies `dest` in place.
"""
function calculate_fastest_split!(dest, time_data, distance_data, target_distances)
    n = length(time_data) # Assuming time and distance data have the same length
    # Early exit if data is empty
    if n == 0
        fill!(dest, typemax(Int))
        return nothing
    end

    # Pre-allocate or check length
    if length(dest) != length(target_distances)
        error("Destination vector length must match target distances length.")
    end

    for (k, target_distance) in enumerate(target_distances)
        # Early exit if target distance is non-positive
        if target_distance <= 0.0
            dest[k] = typemax(Int)
            continue
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
        dest[k] = min_split_found ? fastest_split : typemax(Int)
    end
    return nothing
end

get_or_setup_user();

list = Dict(act[:id] => act for act in get_activity_list() |> reduce_subdicts! |> fill_dicts! .|> NamedTuple)
cached_ids = get_cached_activity_ids()
filter!(list) do (k, v)
    name = lowercase(v.type)
    contains(name, "run") &&
        v.private == false &&
        v.manual == false #&&
        # a[:id] ∈ cached_ids
end;

acts = Dict{Int64, NamedTuple{(:distance_data, :time_data, :distance), Tuple{Vector{Float32}, Vector{Int64}, Float32}}}()

for id in keys(list)
    dist, time = if id ∈ cached_ids
        get_cached_activity_stream(id, :distance),
        get_cached_activity_stream(id, :time)
    else
        get_activity_stream(id, :distance),
        get_activity_stream(id, :time)
    end

    if !ismissing(dist) && !ismissing(time) && haskey(dist, :data) && haskey(time, :data)
        acts[id] = (
            distance_data = dist[:data],
            time_data = time[:data],
            distance = Float32(list[id].distance)
        )
    else
        error("Missing or invalid data for activity ID: $id")
    end
end

# scales activities with corrected distances
for id in keys(acts)
    scale = acts[id].distance / acts[id].distance_data[end]

    if abs(scale - 1) > 0.01
        acts[id].distance_data .*= scale
    end
end

function floor_to_factor(x, factor)
    return floor(x / factor) * factor
end

race_distances_meters = [400, 804, 1000, 1609, 3219, 5000, 8045, 10000, 15000, 16093, 20000, 21097, 30000, 42195, 50000]
race_distances = meter_to_mile.(race_distances_meters)
max_distance = getproperty.(values(acts), :distance) |> maximum |> meter_to_mile
filter!(race_distances) do d
    d <= max_distance
end

res = 0.5
rng = vcat(race_distances, 1:res:floor_to_factor(max_distance, res))
sort!(rng)
unique!(rng)
target_distances_meters = mile_to_meter.(rng)

paces = fill!(Matrix{Float32}(undef, length(rng), length(list)), Inf32) # Initialize with Inf
times = fill!(Matrix{Int}(undef, length(rng), length(list)), typemax(Int)) # Initialize with typemax(Int)

ids = collect(keys(list)) # Collect keys to avoid re-evaluating keys in the loop

# Update the threaded loop to use enumerate(ids) again
@time @inbounds Threads.@threads for (col_idx, id) in enumerate(ids) |> collect # Revert back to enumerate
    act = acts[id]

    time_data = act.time_data
    distance_data = act.distance_data

    # Use the mutating function with a view of the times matrix column
    calculate_fastest_split!(@view(times[:, col_idx]), time_data, distance_data, target_distances_meters)
end

paces .= ifelse.(times .== typemax(Int), Inf, (times ./ 60.0) ./ rng) # Use Inf for invalid times

max_paces = minimum.(eachrow(paces), init = Inf32)
replace!(max_paces, Inf32 => missing) # Keep missing for plotting gaps

# plot rng, max_paces

function pace_to_str(time_min::Real)::String
    hrs = floor(Int, time_min / 60)
    mins = floor(Int, time_min % 60)
    secs = round(Int, (time_min - hrs * 60 - mins) * 60)
    if hrs > 0
        return string(hrs, ":", lpad(mins, 2, "0"), ":", lpad(secs, 2, "0"))
    else
        return string(mins, ":", lpad(secs, 2, "0"))
    end
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
        yreversed = true
    )

    # xlims!(ax, 0, maximum(rng))
    ylims!(ax, maximum(max_paces), minimum(max_paces))


    lines!(
        ax, rng, max_paces, color = :black, label = "Fastest split",
    )

    # vlines!(ax, race_distances, 0, maximum(max_paces), color = :lightgreen, label = "5k")

    for (i, id) in enumerate(ids)
        act = acts[id]
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

    fig
end

save("examples/fastest_splits.png", fig)

dist_names = ["400m", "1/2 mile", "1K", "1 mile", "2 mile", "5K", "5 Mile", "10K", "15K", "10 mile", "20K", "Half-Marathon", "30K", "Marathon", "50K"]
for (name, dist) in zip(dist_names[eachindex(race_distances)], race_distances)
    idx = findfirst(==(dist), rng)
    # Need to handle potential Inf values when finding the minimum pace
    row_paces = @view paces[idx, :]
    valid_indices = findall(isfinite, row_paces)
    if isempty(valid_indices)
        println("$(dist) miles: No valid pace found.")
        continue
    end
    min_pace, rel_idx = findmin(@view row_paces[valid_indices])
    idx2 = valid_indices[rel_idx]


    id = ids[idx2]
    detail_idx = findfirst(a -> a[:id] == id, list)

    details = if !isnothing(detail_idx)
        list[detail_idx]
    else
        Dict(:id => id, :name => "Unknown (ID not found in list)")
    end

    time = times[idx, idx2]
    time_str = pace_to_str(time / 60.0)
    pace_str = pace_to_str(min_pace)
    
    @printf("%-13s | %7s | %5s min/mi | %s | %s https://www.strava.com/activities/%d\n",
        name, time_str, pace_str, details[:start_date_local], details[:name], details[:id]
    )
end
