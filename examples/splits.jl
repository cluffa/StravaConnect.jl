using Pkg; Pkg.activate(@__DIR__); Pkg.instantiate()

using Revise
using Makie
using CairoMakie
using StravaConnect
using Printf
using Statistics

@info pathof(StravaConnect)

# Unit conversion constants and functions
const METERS_PER_MILE = 1609.34
const SECONDS_PER_MINUTE = 60.0

meter_to_mile(x) = x / METERS_PER_MILE
mile_to_meter(x) = x * METERS_PER_MILE

# Standard race distances and their names for plotting
const RACE_INFO = [
    (meter_to_mile(400), "400m"),
    (0.5, "1/2 mile"),
    (meter_to_mile(1000), "1K"),
    (1.0, "1 mile"),
    (2.0, "2 mile"),
    (meter_to_mile(5000), "5K"),
    (5.0, "5 mile"),
    (meter_to_mile(10000), "10K"),
    (meter_to_mile(15000), "15K"),
    (10.0, "10 mile"),
    (meter_to_mile(20000), "20K"),
    (meter_to_mile(21097), "Half Marathon"),
    (meter_to_mile(30000), "30K"),
    (meter_to_mile(42195), "Marathon"),
    (meter_to_mile(50000), "50K"),
    (50.0, "50 mile"),
    (meter_to_mile(100000), "100K"),
    (100.0, "100 mile")
]

"""
    calculate_fastest_split!(dest::AbstractVector{Int}, time_data::AbstractVector{Int}, distance_data::AbstractVector{<:AbstractFloat}, target_distances::AbstractVector{<:AbstractFloat})

Calculates the fastest split time in seconds for given distances using an optimized sliding window algorithm.

The algorithm uses a two-pointer sliding window approach to efficiently find the minimum time
for each target distance without nested loops.

# Arguments
- `dest::AbstractVector{Int}`: Pre-allocated vector to store the calculated fastest split times in seconds.
- `time_data::AbstractVector{Int}`: Vector of timestamps in seconds (must be sorted).
- `distance_data::AbstractVector{<:AbstractFloat}`: Vector of cumulative distances in meters (must be sorted, Float32 or Float64).
- `target_distances::AbstractVector{<:AbstractFloat}`: Vector of desired distances for the splits in meters (Float32 or Float64).

# Returns
- `Nothing`: The function modifies `dest` in place.

# Performance
- Time complexity: O(n * m) where n is the length of data and m is the number of target distances
- Space complexity: O(1) additional space
"""
function calculate_fastest_split!(dest::AbstractVector{Int}, time_data::AbstractVector{Int}, 
                                distance_data::AbstractVector{<:AbstractFloat}, target_distances::AbstractVector{<:AbstractFloat})
    n = length(time_data)
    
    # Input validation
    length(time_data) == length(distance_data) || 
        throw(ArgumentError("time_data and distance_data must have the same length"))
    length(dest) == length(target_distances) || 
        throw(ArgumentError("dest length must match target_distances length"))
    
    # Early exit for empty data
    if n == 0
        fill!(dest, typemax(Int))
        return nothing
    end

    @inbounds for (k, target_distance) in enumerate(target_distances)
        # Skip non-positive target distances
        if target_distance ≤ 0.0
            dest[k] = typemax(Int)
            continue
        end

        fastest_split = typemax(Int)
        i, j = 1, 1
        
        # Sliding window algorithm
        while j ≤ n
            current_distance = distance_data[j] - distance_data[i]
            
            if current_distance ≥ target_distance
                # Found a valid split, check if it's faster
                split_time = time_data[j] - time_data[i]
                fastest_split = min(fastest_split, split_time)
                
                # Try to shrink window from left
                i += 1
                # Reset j if i overtook it
                if i > j
                    j = i
                end
            else
                # Expand window to right
                j += 1
            end
        end
        
        dest[k] = fastest_split
    end
    return nothing
end

"""
    load_and_filter_activities()

Load activities from Strava and filter for valid running activities.

# Returns
- `Dict`: Dictionary mapping activity ID to activity metadata
"""
function load_and_filter_activities()
    @info "Loading activity list..."
    activities = get_activity_list() |> reduce_subdicts! |> fill_dicts! .|> NamedTuple
    
    # Create lookup dictionary
    activity_dict = Dict(act[:id] => act for act in activities)
    
    # Filter for valid running activities
    filter!(activity_dict) do (k, v)
        name = lowercase(v.type)
        contains(name, "run") && 
        !v.private && 
        !v.manual
    end
    
    @info "Found $(length(activity_dict)) valid running activities"
    return activity_dict
end

"""
    load_activity_streams(activity_list::Dict)

Load distance and time streams for all activities.

# Arguments
- `activity_list::Dict`: Dictionary of activity metadata

# Returns
- `Dict`: Dictionary mapping activity ID to (distance_data, time_data, distance) tuple
"""
function load_activity_streams(activity_list::Dict)
    @info "Loading activity streams..."
    cached_ids = get_cached_activity_ids()
    activities_data = Dict{Int64, NamedTuple{(:distance_data, :time_data, :distance), 
                                           Tuple{Vector{Float32}, Vector{Int64}, Float32}}}()
    
    failed_loads = Int[]
    
    for id in keys(activity_list)
        try
            # Use cached data if available
            dist, time = if id ∈ cached_ids
                get_cached_activity_stream(id, :distance),
                get_cached_activity_stream(id, :time)
            else
                get_activity_stream(id, :distance),
                get_activity_stream(id, :time)
            end

            if !ismissing(dist) && !ismissing(time) && 
               haskey(dist, :data) && haskey(time, :data) &&
               !isempty(dist[:data]) && !isempty(time[:data])
                
                activities_data[id] = (
                    distance_data = dist[:data],
                    time_data = time[:data],
                    distance = Float32(activity_list[id].distance)
                )
            else
                push!(failed_loads, id)
            end
        catch e
            @warn "Failed to load data for activity $id: $e"
            push!(failed_loads, id)
        end
    end
    
    if !isempty(failed_loads)
        @warn "Failed to load $(length(failed_loads)) activities: $failed_loads"
    end
    
    @info "Successfully loaded $(length(activities_data)) activity streams"
    return activities_data
end

"""
    correct_distance_scales!(activities_data::Dict)

Correct distance data scaling based on reported vs. measured total distance.

# Arguments
- `activities_data::Dict`: Dictionary of activity stream data (modified in place)
"""
function correct_distance_scales!(activities_data::Dict)
    @info "Correcting distance scales..."
    corrections_made = 0
    
    for id in keys(activities_data)
        reported_distance = activities_data[id].distance
        measured_distance = activities_data[id].distance_data[end]
        scale_factor = reported_distance / measured_distance

        # Apply correction if scale differs significantly (>1%)
        if abs(scale_factor - 1) > 0.01
            activities_data[id].distance_data .*= scale_factor
            corrections_made += 1
        end
    end
    
    @info "Applied distance corrections to $corrections_made activities"
end

# Load and prepare data
get_or_setup_user()

activity_list = load_and_filter_activities()
activities_data = load_activity_streams(activity_list)
correct_distance_scales!(activities_data)

"""
    generate_distance_range(max_distance_miles::Float64, resolution::Float64 = 0.5)

Generate a comprehensive range of target distances including standard race distances.

# Arguments
- `max_distance_miles::Float64`: Maximum distance to include in miles
- `resolution::Float64`: Resolution for distance increments in miles

# Returns
- `Vector{Float64}`: Sorted unique distances in miles
"""
function generate_distance_range(max_distance_miles::Float64, resolution::Float64 = 0.5)
    # Standard race distances in meters
    race_distances_meters = [400, 804, 1000, 1609, 3219, 5000, 8045, 10000, 15000, 16093, 20000, 21097, 30000, 42195, 50000]
    race_distances_miles = meter_to_mile.(race_distances_meters)
    
    # Filter race distances within max range
    valid_race_distances = filter(d -> d ≤ max_distance_miles, race_distances_miles)
    
    # Generate regular intervals
    max_floored = floor(max_distance_miles / resolution) * resolution
    regular_distances = collect(1:resolution:max_floored)
    
    # Combine and sort
    all_distances = vcat(valid_race_distances, regular_distances)
    sort!(all_distances)
    unique!(all_distances)
    
    return all_distances
end

"""
    calculate_split_times_parallel(activities_data::Dict, target_distances_miles::Vector{Float64})

Calculate fastest split times for all activities and distances using parallel processing.

# Arguments
- `activities_data::Dict`: Dictionary of activity stream data
- `target_distances_miles::Vector{Float64}`: Target distances in miles

# Returns
- `Tuple{Matrix{Int}, Vector{Int}}`: (times_matrix, activity_ids)
"""
function calculate_split_times_parallel(activities_data::Dict, target_distances_miles::Vector{Float64})
    target_distances_meters = mile_to_meter.(target_distances_miles)
    activity_ids = collect(keys(activities_data))
    n_distances = length(target_distances_miles)
    n_activities = length(activity_ids)
    
    @info "Calculating splits for $n_activities activities and $n_distances distances..."
    
    # Pre-allocate results matrix
    times_matrix = fill(typemax(Int), n_distances, n_activities)
    
    # Parallel computation
    Threads.@threads for (col_idx, id) in collect(enumerate(activity_ids))
        activity = activities_data[id]
        calculate_fastest_split!(
            @view(times_matrix[:, col_idx]), 
            activity.time_data, 
            activity.distance_data, 
            target_distances_meters
        )
    end
    
    return times_matrix, activity_ids
end

# Calculate target distances and split times
max_distance_miles = maximum(getproperty.(values(activities_data), :distance)) |> meter_to_mile
target_distances_miles = generate_distance_range(max_distance_miles)
times_matrix, activity_ids = calculate_split_times_parallel(activities_data, target_distances_miles)

# Convert times to paces (min/mile), handling invalid times
# times_matrix is (n_distances, n_activities), so we need target_distances as a column vector
paces_matrix = ifelse.(times_matrix .== typemax(Int), 
                      Inf32, 
                      (times_matrix ./ SECONDS_PER_MINUTE) ./ target_distances_miles)

# Calculate fastest pace for each distance
fastest_paces = vec(minimum(paces_matrix, dims=2, init=Inf32))
replace!(fastest_paces, Inf32 => missing)  # Use missing for plotting gaps

"""
    pace_to_string(time_minutes::Real)::String

Convert pace in minutes to a formatted time string (M:SS or H:MM:SS).

# Arguments
- `time_minutes::Real`: Time in minutes

# Returns
- `String`: Formatted time string
"""
function pace_to_string(time_minutes::Real)::String
    if !isfinite(time_minutes)
        return "N/A"
    end
    
    total_seconds = round(Int, time_minutes * SECONDS_PER_MINUTE)
    hours = div(total_seconds, 3600)
    minutes = div(total_seconds % 3600, 60)
    seconds = total_seconds % 60
    
    if hours > 0
        return @sprintf("%d:%02d:%02d", hours, minutes, seconds)
    else
        return @sprintf("%d:%02d", minutes, seconds)
    end
end

pace_to_string(paces::AbstractVector) = pace_to_string.(paces)

"""
    create_splits_plot(distances::Vector{Float64}, fastest_paces::Vector, 
                      paces_matrix::Matrix, activity_ids::Vector, activities_data::Dict)

Create a comprehensive splits visualization plot.

# Arguments
- `distances::Vector{Float64}`: Distance values in miles
- `fastest_paces::Vector`: Fastest pace for each distance  
- `paces_matrix::Matrix`: Matrix of all paces
- `activity_ids::Vector`: Vector of activity IDs
- `activities_data::Dict`: Activity metadata

# Returns
- `Figure`: Makie figure object
"""
function create_splits_plot(distances::Vector{Float64}, fastest_paces::Vector, 
                           paces_matrix::Matrix, activity_ids::Vector, activities_data::Dict)
    @info "Creating splits visualization..."
    
    fig = Figure(size=(1200, 800))
    ax = Axis(
        fig[1, 1],
        title = "Fastest Running Splits Analysis",
        xlabel = "Distance",
        ylabel = "Pace (min/mile)",
        xscale = log10,
        xticks = (first.(RACE_INFO), last.(RACE_INFO)),  # Use distance names instead of miles
        xticklabelrotation = π/3,
        ytickformat = pace_to_string,
        yreversed = true
    )

    # Set reasonable y-limits based on data
    valid_paces = filter(isfinite, fastest_paces)
    if !isempty(valid_paces)
        pace_min, pace_max = extrema(valid_paces)
        pace_range = pace_max - pace_min
        ylims!(ax, pace_max + 0.1 * pace_range, pace_min - 0.1 * pace_range)
    end

    # Plot individual activity lines (background)
    for (i, id) in enumerate(activity_ids)
        activity_paces = @view paces_matrix[:, i]
        valid_indices = findall(isfinite, activity_paces)
        
        if !isempty(valid_indices)
            # Check if this activity contributes to any fastest splits
            contributes_to_fastest = any(activity_paces[valid_indices] .== fastest_paces[valid_indices])
            
            lines!(ax, 
                  distances[valid_indices], 
                  activity_paces[valid_indices],
                  color = contributes_to_fastest ? :red : (:blue, 0.3),
                  linewidth = contributes_to_fastest ? 1.5 : 0.5,
                  alpha = contributes_to_fastest ? 0.8 : 0.4
            )
        end
    end

    # Plot fastest splits line (foreground)
    valid_fastest_indices = findall(!ismissing, fastest_paces)
    if !isempty(valid_fastest_indices)
        lines!(ax, 
              distances[valid_fastest_indices], 
              fastest_paces[valid_fastest_indices], 
              color = :black, 
              linewidth = 3,
              label = "Personal Best Splits"
        )
        
        # Add scatter points for race distances
        race_distances = first.(RACE_INFO)
        race_names = last.(RACE_INFO)
        race_point_indices = []
        race_point_paces = []
        race_point_names = []
        
        for (race_dist, race_name) in zip(race_distances, race_names)
            # Find closest distance point to each race distance
            if race_dist <= maximum(distances)
                closest_idx = argmin(abs.(distances .- race_dist))
                if abs(distances[closest_idx] - race_dist) / race_dist < 0.05 && !ismissing(fastest_paces[closest_idx])
                    push!(race_point_indices, closest_idx)
                    push!(race_point_paces, fastest_paces[closest_idx])
                    push!(race_point_names, race_name)
                end
            end
        end
        
        # Plot the race distance points
        if !isempty(race_point_indices)
            scatter!(ax,
                    distances[race_point_indices],
                    race_point_paces,
                    color = :red,
                    markersize = 8,
                    strokecolor = :black,
                    strokewidth = 1,
                    label = "Race Distance PRs"
            )
            
            # Add text labels to the scatter points
            for (i, (x_pos, y_pos, label_text)) in enumerate(zip(distances[race_point_indices], race_point_paces, race_point_names))
                # Format the pace as a time string for the label
                pace_label = pace_to_string(y_pos)
                time_label = pace_to_string(x_pos * y_pos)
                
                text!(ax,
                     x_pos, y_pos,
                     text = "  $label_text ($time_label @ $pace_label/mi)",
                     align = (:left, :center),
                     rotation = π/3,  # Rotate labels
                     fontsize = 9,
                     color = :black
                )
            end
        end
    end

    # Add legend
    axislegend(ax, position = :lb)
    
    return fig
end

# Create and save the visualization
fig = create_splits_plot(target_distances_miles, fastest_paces, paces_matrix, activity_ids, activities_data)
save("examples/fastest_splits.png", fig)

"""
    print_splits_summary(target_distances_miles::Vector{Float64}, times_matrix::Matrix{Int}, 
                         paces_matrix::Matrix, activity_ids::Vector, activity_list::Dict)

Print a formatted summary of fastest splits for standard race distances.

# Arguments
- `target_distances_miles::Vector{Float64}`: Distance values in miles
- `times_matrix::Matrix{Int}`: Matrix of split times
- `paces_matrix::Matrix`: Matrix of paces  
- `activity_ids::Vector`: Vector of activity IDs
- `activity_list::Dict`: Activity metadata dictionary
"""
function print_splits_summary(target_distances_miles::Vector{Float64}, times_matrix::Matrix{Int}, 
                             paces_matrix::Matrix, activity_ids::Vector, activity_list::Dict)
    
    println("\n" * "="^100)
    println("FASTEST SPLITS SUMMARY")
    println("="^100)
    println(@sprintf("%-15s | %8s | %10s | %12s | %-25s | %s", 
            "Distance", "Time", "Pace", "Date", "Activity Name", "URL"))
    println("-"^100)
    
    for (distance_miles, name) in RACE_INFO
        # Find closest distance in our range
        distance_idx = argmin(abs.(target_distances_miles .- distance_miles))
        actual_distance = target_distances_miles[distance_idx]
        
        # Skip if distance is too far from target (>5% difference)
        if abs(actual_distance - distance_miles) / distance_miles > 0.05
            continue
        end
        
        # Find fastest time for this distance
        distance_paces = @view paces_matrix[distance_idx, :]
        valid_indices = findall(isfinite, distance_paces)
        
        if isempty(valid_indices)
            println(@sprintf("%-15s | %8s | %10s | %12s | %-25s | %s", 
                    name, "N/A", "N/A", "N/A", "No data", ""))
            continue
        end
        
        fastest_pace, rel_idx = findmin(@view distance_paces[valid_indices])
        activity_idx = valid_indices[rel_idx]
        activity_id = activity_ids[activity_idx]
        
        # Get activity details
        activity = get(activity_list, activity_id, nothing)
        if activity === nothing
            activity_name = "Unknown Activity"
            date_str = "Unknown"
        else
            activity_name = get(activity, :name, "Unnamed")
            # Truncate long names
            if length(activity_name) > 25
                activity_name = activity_name[1:22] * "..."
            end
            date_str = string(get(activity, :start_date_local, "Unknown"))[1:10]  # Just the date part
        end
        
        # Format time and pace
        split_time = times_matrix[distance_idx, activity_idx]
        time_str = pace_to_string(split_time / SECONDS_PER_MINUTE)
        pace_str = pace_to_string(fastest_pace)
        
        # Create Strava URL
        strava_url = "https://www.strava.com/activities/$activity_id"
        
        println(@sprintf("%-15s | %8s | %10s | %12s | %-25s | %s", 
                name, time_str, pace_str, date_str, activity_name, strava_url))
    end
    
    println("="^100)
end

# Print the summary
print_splits_summary(target_distances_miles, times_matrix, paces_matrix, activity_ids, activity_list)