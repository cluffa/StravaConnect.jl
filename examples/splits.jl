using Pkg; Pkg.activate(@__DIR__); Pkg.instantiate()

using Revise
using Makie
# using WGLMakie
using CairoMakie
using StravaConnect

@info pathof(StravaConnect)

meter_to_mile(x::Real)::Real = x / 1609.34
mile_to_meter(x::Real)::Real = x * 1609.34

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
function calculate_fastest_split!(dest::AbstractVector{Int}, time_data::Vector{Int}, distance_data::Vector{Float64}, target_distances::Vector{Float64})
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

list = get_activity_list() |> reduce_subdicts! |> fill_dicts!;
cached_ids = get_cached_activity_ids()
filter!(list) do a
    contains(lowercase(a[:type]), "run") &&
        a[:id] ∈ cached_ids
end;

distances = Dict{Int64, Float64}(l[:id] => l[:distance] for l in list)

actDict = Dict(
    id => Dict{Symbol, Any}(
        :distance_data => get_cached_activity_stream(id, :distance)[:data],
        :time_data => get_cached_activity_stream(id, :time)[:data]
        ) for id in getindex.(list, :id)
    )

# scales activities with corrected distances
for id in getindex.(list, :id)
    if haskey(actDict[id], :distance_data) && !isempty(actDict[id][:distance_data]) # Check if distance_data exists and is not empty
        # Ensure correct types after fetching
        if !(actDict[id][:time_data] isa Vector{Int})
             actDict[id][:time_data] = Vector{Int}(actDict[id][:time_data])
        end
        if !(actDict[id][:distance_data] isa Vector{Float64})
             actDict[id][:distance_data] = Vector{Float64}(actDict[id][:distance_data])
        end

        # Check again after potential conversion, as conversion might yield empty
        if !isempty(actDict[id][:distance_data])
            scale = distances[id] / actDict[id][:distance_data][end]
            actDict[id][:scale] = scale
            if scale != 1.0
                actDict[id][:distance_data] .*= scale
            end
        else
             # Handle cases where distance data became empty after conversion or was initially empty
             # Maybe remove the entry or mark it as invalid? For now, just skip scaling.
             delete!(actDict, id) # Remove activity if essential data is missing/empty
        end
    elseif haskey(actDict, id) # If distance_data is missing entirely
        delete!(actDict, id) # Remove activity if essential data is missing
    end
end

# Filter list and ids based on remaining keys in actDict after cleaning
filter!(list) do a
    haskey(actDict, a[:id])
end
ids = getindex.(list, :id) # Update ids based on the filtered list

# Remove the unused 'acts' variable allocation
# acts = values(actDict) |> collect

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

paces = fill!(Matrix{Float64}(undef, length(rng), length(list)), Inf) # Initialize with Inf
times = fill!(Matrix{Int}(undef, length(rng), length(list)), typemax(Int)) # Initialize with typemax(Int)

ids = getindex.(list, :id)

# Update the threaded loop to use enumerate(ids) again
@time @inbounds Threads.@threads for (col_idx, id) in enumerate(ids) |> collect # Revert back to enumerate
    # Check if id still exists in actDict (might have been deleted if data was bad)
    # This check might be redundant if ids is correctly updated after cleaning actDict,
    # but adds safety.
    if !haskey(actDict, id)
        # If an id was removed, fill its corresponding time column with typemax(Int)
        times[:, col_idx] .= typemax(Int)
        continue
    end
    act = actDict[id]

    # Type conversions are now done earlier, assuming they succeeded.
    # If they failed, the entry should have been removed from actDict and ids.
    time_data = act[:time_data]
    distance_data = act[:distance_data]

    # Handle potentially empty data streams even after initial checks
    if isempty(time_data) || isempty(distance_data)
         times[:, col_idx] .= typemax(Int)
         continue
    end

    # Use the mutating function with a view of the times matrix column
    calculate_fastest_split!(@view(times[:, col_idx]), time_data, distance_data, target_distances_meters)
end

paces .= ifelse.(times .== typemax(Int), Inf, (times ./ 60.0) ./ rng) # Use Inf for invalid times

max_paces = minimum.(eachrow(paces), init = Inf) # Remove skipmissing
replace!(max_paces, Inf => missing) # Keep missing for plotting gaps

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
        yreversed = true # Invert the y-axis
    )

    # xlims!(ax, 0, maximum(rng))
    # Adjust ylims for reversed axis: max value first, min value second
    ylims!(ax, maximum(max_paces), minimum(max_paces))


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
    # Need to handle potential Inf values when finding the minimum pace
    row_paces = @view paces[idx, :] # Use @view to avoid allocation
    valid_indices = findall(isfinite, row_paces) # Find finite values (not Inf)
    if isempty(valid_indices)
        println("$(dist) miles: No valid pace found.")
        continue
    end
    min_pace, rel_idx = findmin(@view row_paces[valid_indices]) # findmin ignores Inf implicitly if finite values exist
    idx2 = valid_indices[rel_idx]


    id = ids[idx2]
    # Use findfirst to get the index of the matching activity in list
    detail_idx = findfirst(a -> a[:id] == id, list)

    details = if !isnothing(detail_idx)
        list[detail_idx]
    else
        # Fallback if somehow the id isn't found in the filtered list
        Dict(:id => id, :name => "Unknown (ID not found in list)")
    end


    pace_str = pace_to_str(min_pace)

    println("$(dist) miles: $(pace_str) in activity $(details[:name]) https://www.strava.com/activities/$(details[:id])")
end