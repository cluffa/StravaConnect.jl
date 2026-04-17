using JLD2
using SQLite
using StravaConnect

function migrate_jld2_to_sqlite(data_dir::String)
    jld2_file = joinpath(data_dir, "data.jld2")
    if !isfile(jld2_file)
        @info "No JLD2 file found at $jld2_file, skipping migration."
        return
    end

    @info "Migrating data from JLD2 to SQLite..."
    db = StravaConnect.init_db(data_dir)
    
    SQLite.transaction(db) do
        jldopen(jld2_file, "r") do io
            # Migrate activity list
            if haskey(io, "activities")
                activities = io["activities"]
                for act in activities
                    id = Int(act[:id])
                    StravaConnect.save_activity_metadata!(db, id, act, 0)
                end
                @info "Migrated $(length(activities)) activity metadata entries."
            end
            
            # Migrate individual activity streams
            if haskey(io, "activity")
                activity_group = io["activity"]
                for id_str in keys(activity_group)
                    id = parse(Int, id_str)
                    streams = activity_group[id_str]
                    for stream_type in keys(streams)
                        StravaConnect.save_stream!(db, id, string(stream_type), streams[stream_type])
                    end
                end
                @info "Migrated detailed activity data."
            end
            
            # Migrate mtime
            if haskey(io, "mtime")
                StravaConnect.set_cached_mtime!(db, io["mtime"])
            end
        end
    end
    
    # Rename the old file instead of deleting it
    mv(jld2_file, jld2_file * ".migrated", force=true)
    @info "Migration complete. Old file renamed to $(jld2_file).migrated"
end
