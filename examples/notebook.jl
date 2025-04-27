### A Pluto.jl notebook ###
# v0.20.6

using Markdown
using InteractiveUtils

# ╔═╡ 7f3bc67a-223b-11f0-1022-ebd718969be0
begin
	import Pkg
	Pkg.activate(".")
	using StravaConnect
	using WGLMakie
	using WGLMakie.Makie
end

# ╔═╡ a1bcb071-b8e8-40e7-b9a1-3886756f456e
@info pathof(StravaConnect)

# ╔═╡ 6dd1ccb5-94c1-4a1d-86b1-33f4db51c005
meter_to_mile(x::Real)::Real = x / 1609.34

# ╔═╡ fb2fde68-43c2-4029-85b5-12d484a14c8f
mile_to_meter(x::Real)::Real = x * 1609.34

# ╔═╡ 49fbb104-65f8-4412-8abe-93511c3edcc8
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
function calculate_fastest_split(time_data::Vector{Int}, distance_data::Vector{Float64}, (heartrate_data::Vector{Int}), target_distance::Float64)::Union{Tuple{Int, Float64}, Tuple{Missing, Missing}}
    n = length(time_data) # Assuming time and distance data have the same length
    # Early exit if data is empty or target distance is non-positive
    if n == 0 || target_distance <= 0.0
        return missing
    end

    i = 1 # start index
    j = 1 # end index
    fastest_split = typemax(Int)
    min_split_found = false # Flag to track if any valid split was found
	avg_hr = 0.0
    @inbounds while j <= n && i <= n
        current_distance = distance_data[j] - distance_data[i]

        if current_distance >= target_distance
            # Potential split found
            split_time = time_data[j] - time_data[i]
            if split_time < fastest_split
                fastest_split = split_time
				avg_hr = sum(heartrate_data[i:j]) / length(i:j)
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

    return min_split_found ? (fastest_split, avg_hr) : (missing, missing)
end

# ╔═╡ 081de0e6-4cd1-4292-8f60-65ed4c1f551d
get_or_setup_user();

# ╔═╡ 268e4101-52ce-4e8f-a9ce-0d45e5ec9787
begin
	list = get_activity_list() |> reduce_subdicts! |> fill_dicts!;
	cached_ids = get_cached_activity_ids()
	filter!(list) do a
	    contains(lowercase(a[:type]), "run") &&
	        a[:id] ∈ cached_ids &&
			!isnothing(a[:average_heartrate])
	end;
end

# ╔═╡ 2d5eb2b8-54f1-406f-b863-a9e9aed18e7e
distances = Dict{Int64, Float64}(l[:id] => l[:distance] for l in list)

# ╔═╡ b559cd06-9324-4501-8dc5-4eb36fb63be0
begin
	actDict = Dict(
	    id => Dict{Symbol, Any}(
	        :distance_data => get_cached_activity_stream(id, :distance)[:data],
	        :time_data => get_cached_activity_stream(id, :time)[:data],
			:heartrate_data => get_cached_activity_stream(id, :heartrate)[:data]
	        ) for id in getindex.(list, :id)
	    )
	
	for id in getindex.(list, :id)
	    if haskey(actDict[id], :distance_data)
	        scale = distances[id] / actDict[id][:distance_data][end]
	        actDict[id][:scale] = scale
	        if scale != 1.0
	            actDict[id][:distance_data] .*= scale
	        end
	    end
	end
end

# ╔═╡ 8b11f2bc-72e2-4e43-b003-d4a7ab391f42
acts = values(actDict) |> collect

# ╔═╡ 2ac4ae8a-4c85-47dc-9178-8416013043b0
function floor_to_factor(x::Real, factor::Real)
    return floor(x / factor) * factor
end

# ╔═╡ 2a1f6996-4592-47d6-8643-7880f455c733
begin
	race_distances = [3.1, 6.2, 13.1, 26.2, 31.1, 50.0, 100.0]
	max_distance = distances |> values |> maximum |> meter_to_mile
	filter!(race_distances) do d
	    d <= max_distance
	end
	
end

# ╔═╡ be6a7030-4d56-4b0c-9350-0a233003fe32
ids = getindex.(list, :id)

# ╔═╡ eb82243a-e32c-4b7f-9212-1ec5b1f1ab71
function pace_to_str(pace::Real)::String
    pace_min = floor(pace) |> Int
    pace_sec = floor((pace - pace_min) * 60) |> Int
    return string(pace_min, ":", lpad(pace_sec, 2, "0"))
end

# ╔═╡ 3ea36766-b218-40df-afbf-03a20d34563b
pace_to_str(paces::Vector)::Vector{String} = pace_to_str.(paces)

# ╔═╡ ca643ad7-c66d-418d-a4c8-c3caf03082a5
res, start = 0.05, 1.0

# ╔═╡ 3b509825-92c0-438d-b12b-984a52f7a241
begin
	rng = vcat(race_distances, start:res:floor_to_factor(max_distance, res))
	sort!(rng)
	unique!(rng)
end

# ╔═╡ ad593273-2b63-46c9-9ee9-c533f126cd82
target_distances_meters = mile_to_meter.(rng) # Pre-calculate target distances in meters

# ╔═╡ 5c1f267c-de4e-4a71-972f-68d0ec51f390
begin
	times = fill!(Matrix{Union{Tuple{Missing, Missing}, Tuple{Int, Float64}}}(undef, length(rng), length(list)), (missing, missing)) # Use Int for time
	paces = fill!(Matrix{Union{Missing, Float64}}(undef, length(rng), length(list)), missing)
	
	@inbounds Threads.@threads for (col_idx, id) in enumerate(ids) |> collect
	    act = actDict[id]
	
	    time_data = act[:time_data] isa Vector{Int} ? act[:time_data] : Vector{Int}(act[:time_data])
	    distance_data = act[:distance_data] isa Vector{Float64} ? act[:distance_data] : Vector{Float64}(act[:distance_data])
		heartrate_data = act[:heartrate_data] isa Vector{Int} ? act[:heartrate_data] : Vector{Int}(act[:heartrate_data])
		
	    times[:, col_idx] .= calculate_fastest_split.((time_data,), (distance_data,), (heartrate_data,), target_distances_meters)
	end
end

# ╔═╡ a543eedf-d333-442f-af67-2e83f6a12a36
times

# ╔═╡ e9e611e6-8ab9-4c1c-85e6-33dc0cbb1f13
hrs = last.(times)

# ╔═╡ 26a988b0-ecd5-4432-beab-3b9840fc6ed1
paces .= ifelse.(ismissing.(first.(times)), missing, (first.(times) ./ 60.0) ./ rng)

# ╔═╡ 9b5c4a38-17dc-4927-8cbc-d23ba77be1df
begin
	max_paces = minimum.(skipmissing.(eachrow(paces)), init = Inf)
    fig = Figure(size = (690, 300))
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
end; fig

# ╔═╡ a04035c6-e3ad-4763-bf88-fc996d18b470
begin
	out = ["| Distance | Pace | Heartrate | Activity |\n", "| :-------- | :-------- | :------- | :-------- |\n"]
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
	
	    push!(out, """| $(dist) | $(pace_str) | $(round(hrs[idx, idx2], digits = 1)) | [$(details[:name])](https://www.strava.com/activities/$(details[:id])) | \n""")
	end

	Markdown.parse(join(out))
end

# ╔═╡ Cell order:
# ╠═7f3bc67a-223b-11f0-1022-ebd718969be0
# ╠═a1bcb071-b8e8-40e7-b9a1-3886756f456e
# ╠═6dd1ccb5-94c1-4a1d-86b1-33f4db51c005
# ╠═fb2fde68-43c2-4029-85b5-12d484a14c8f
# ╠═49fbb104-65f8-4412-8abe-93511c3edcc8
# ╠═081de0e6-4cd1-4292-8f60-65ed4c1f551d
# ╠═268e4101-52ce-4e8f-a9ce-0d45e5ec9787
# ╠═2d5eb2b8-54f1-406f-b863-a9e9aed18e7e
# ╠═b559cd06-9324-4501-8dc5-4eb36fb63be0
# ╠═8b11f2bc-72e2-4e43-b003-d4a7ab391f42
# ╠═2ac4ae8a-4c85-47dc-9178-8416013043b0
# ╠═2a1f6996-4592-47d6-8643-7880f455c733
# ╠═3b509825-92c0-438d-b12b-984a52f7a241
# ╠═ad593273-2b63-46c9-9ee9-c533f126cd82
# ╠═be6a7030-4d56-4b0c-9350-0a233003fe32
# ╠═5c1f267c-de4e-4a71-972f-68d0ec51f390
# ╠═a543eedf-d333-442f-af67-2e83f6a12a36
# ╠═26a988b0-ecd5-4432-beab-3b9840fc6ed1
# ╠═e9e611e6-8ab9-4c1c-85e6-33dc0cbb1f13
# ╠═eb82243a-e32c-4b7f-9212-1ec5b1f1ab71
# ╠═3ea36766-b218-40df-afbf-03a20d34563b
# ╠═ca643ad7-c66d-418d-a4c8-c3caf03082a5
# ╠═9b5c4a38-17dc-4927-8cbc-d23ba77be1df
# ╠═a04035c6-e3ad-4763-bf88-fc996d18b470
