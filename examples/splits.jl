using Pkg; Pkg.activate(@__DIR__); Pkg.instantiate()

using Revise
using WGLMakie
using WGLMakie.Makie
using WGLMakie.Colors
using StravaConnect

@info pathof(StravaConnect)

meter_to_mile(x::Real)::Real = x / 1609.34
mile_to_meter(x::Real)::Real = x * 1609.34

"""
    calculate_fastest_split(activity_data::Dict, split_distance_meters::Float64) -> Int

Calculates the fastest split time in seconds for a given distance.

# Arguments
- `activity_data::Dict`: A dictionary containing activity streams, specifically `:time_data` (Vector{Int}) and `:distance_data` (Vector{Float64}).
- `split_distance_meters::Float64`: The desired distance for the split in meters.

# Returns
- `Int`: The fastest split time in seconds for the specified distance. Returns `typemax(Int)` if no split of that distance is found.
"""
function calculate_fastest_split(act, distance::Float64=1.0; in_miles=true)
    if in_miles
        split_distance_meters = mile_to_meter(distance) # Convert miles to meters
    else
        split_distance_meters = distance # Already in meters
    end

    # calculates fastest split for a given distance
    i = 1 # start index
    j = 1 # end index
    distance_data = act[:distance_data]
    time_data = act[:time_data]
    n = length(time_data) # Assuming time and distance data have the same length
    fastest_split = typemax(Int)
    while j <= n && i <= n
        # Ensure indices are valid before accessing
        current_distance = distance_data[j] - distance_data[i]

        if current_distance >= split_distance_meters
            split_time = time_data[j] - time_data[i]
            if split_time < fastest_split
                fastest_split = split_time
            end
            i += 1
        else
            j += 1
        end
        if i > j && j <= n
            j = i
        end
    end
    if fastest_split == typemax(Int)
        return missing
    end
    return fastest_split
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

paces = fill!(Matrix{Union{Missing, Float64}}(undef, length(rng), length(list)), missing)
times = fill!(Matrix{Union{Missing, Float64}}(undef, length(rng), length(list)), missing)

ids = getindex.(list, :id)

Threads.@threads for (i, id) in enumerate(ids) |> collect
    act = actDict[id]
    if haskey(act, :time_data) && haskey(act, :distance_data)
        times[:, i] .= [(calculate_fastest_split(act, d)/60) for d in rng]
        paces[:, i] .= times[:, i] ./ rng
    end
end

max_paces = minimum.(skipmissing.(eachrow(paces)), init = Inf)
replace!(max_paces, Inf => missing)

# plot rng, max_paces

begin
    fig = Figure()
    ax = Axis(
        fig[1, 1],
        title = "Fastest splits",
        xlabel = "Distance (miles)",
        ylabel = "Pace (min/mile)",   
    )

    xlims!(ax, 0, maximum(rng))
    ylims!(ax, minimum(max_paces), maximum(max_paces))

    lines!(
        ax, rng, max_paces, color = :black, label = "Fastest split",
        # inspector_label = (plot, idx, pos) -> begin
        #     pace = max_paces[idx]
        #     dist = rng[idx]
        #     isnothing(pace) || ismissing(pace) ? "No data" :
        #         "Distance: $(round(dist, digits=2)) mi\nPace: $(round(pace, digits=2)) min/mi"
        # end
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
    pace, idx2 = findmin(skipmissing(paces[idx, :]))

    id = ids[idx2]
    details = filter(list) do a
        a[:id] == id
    end
    details = length(details) > 0 ? first(details) : Dict(:id => id, :name => "Unknown")
    act = actDict[id]

    pace_min = floor(pace) |> Int
    pace_sec = floor((pace - pace_min) * 60) |> Int
    pace_str = string(pace_min, ":", lpad(pace_sec, 2, "0"))
    println("Fastest split for $(dist) miles: $(pace_str) in activity $(details[:name]) $(details[:id])")
end