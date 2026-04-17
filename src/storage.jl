using SQLite
using JSON3
using Dates

function get_db_path(data_dir::String)
    return joinpath(data_dir, "data.sqlite")
end

function init_db(data_dir::String)
    db_path = get_db_path(data_dir)
    if !isdir(data_dir)
        mkpath(data_dir)
    end
    db = SQLite.DB(db_path)
    
    # Set busy timeout to 5 seconds to handle transient locks
    SQLite.execute(db, "PRAGMA busy_timeout = 5000")
    
    # Activities table: id, metadata (json), mtime, start_date
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS activities (
            id INTEGER PRIMARY KEY,
            metadata TEXT,
            mtime INTEGER,
            start_date INTEGER
        )
    """)
    
    # Ensure start_date column exists (for migration from previous SQLite version)
    try
        SQLite.execute(db, "ALTER TABLE activities ADD COLUMN start_date INTEGER")
    catch e
        # Column likely already exists
    end
    
    # Streams table: activity_id, stream_type, data (json)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS streams (
            activity_id INTEGER,
            stream_type TEXT,
            data BLOB,
            PRIMARY KEY (activity_id, stream_type),
            FOREIGN KEY (activity_id) REFERENCES activities(id)
        )
    """)
    
    # Cache metadata table (for overall mtime of the activity list)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS cache_metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        )
    """)
    
    return db
end

function save_activity_metadata!(db::SQLite.DB, id::Int, metadata::Dict, mtime::Int)
    metadata_json = JSON3.write(metadata)
    # Parse start_date from metadata if possible
    start_date_unix = 0
    if haskey(metadata, :start_date)
        try
            start_date_unix = Int(floor(datetime2unix(DateTime(metadata[:start_date][1:19]))))
        catch
        end
    end
    
    SQLite.execute(db, "INSERT OR REPLACE INTO activities (id, metadata, mtime, start_date) VALUES (?, ?, ?, ?)", 
                   (id, metadata_json, mtime, start_date_unix))
end

function get_max_start_date(db::SQLite.DB)
    result = SQLite.DBInterface.execute(db, "SELECT MAX(start_date) as max_sd FROM activities")
    for row in result
        val = row.max_sd
        return ismissing(val) ? 0 : Int(val)
    end
    return 0
end

function save_stream!(db::SQLite.DB, activity_id::Int, stream_type::String, data::Dict)
    # Handle NaN values which are not allowed in standard JSON
    # We create a copy of the dict and replace NaNs in the :data vector
    clean_data = Dict{Symbol, Any}()
    for (k, v) in data
        if k == :data && v isa AbstractVector && eltype(v) <: AbstractFloat
            clean_data[k] = [isnan(x) ? nothing : x for x in v]
        else
            clean_data[k] = v
        end
    end
    
    data_json = JSON3.write(clean_data)
    SQLite.execute(db, "INSERT OR REPLACE INTO streams (activity_id, stream_type, data) VALUES (?, ?, ?)", (activity_id, stream_type, data_json))
end

function get_cached_metadata_all(db::SQLite.DB)
    results = SQLite.DBInterface.execute(db, "SELECT metadata FROM activities")
    out = Dict{Symbol, Any}[]
    for row in results
        val = row[1]
        if !ismissing(val)
            push!(out, JSON3.read(val, Dict{Symbol, Any}))
        end
    end
    return out
end

function get_cached_mtime(db::SQLite.DB)
    result = SQLite.DBInterface.execute(db, "SELECT value FROM cache_metadata WHERE key = 'mtime'")
    for row in result
        val = row[1]
        if !ismissing(val)
            return parse(Int, val)
        end
    end
    return 0
end

function set_cached_mtime!(db::SQLite.DB, mtime::Int)
    SQLite.execute(db, "INSERT OR REPLACE INTO cache_metadata (key, value) VALUES ('mtime', ?)", (string(mtime),))
end

function get_cached_activity_db(db::SQLite.DB, id::Int)
    result = SQLite.DBInterface.execute(db, "SELECT metadata FROM activities WHERE id = ?", (id,))
    
    activity = missing
    for row in result
        val = row[1]
        if !ismissing(val)
            activity = JSON3.read(val, Dict{Symbol, Any})
        end
    end
    
    if !ismissing(activity)
        # Load streams
        streams = SQLite.DBInterface.execute(db, "SELECT stream_type, data FROM streams WHERE activity_id = ?", (id,))
        for s_row in streams
            type_val = s_row[1]
            data_val = s_row[2]
            if !ismissing(type_val) && !ismissing(data_val)
                activity[Symbol(type_val)] = JSON3.read(data_val, Dict{Symbol, Any})
            end
        end
    end
    
    return activity
end

function get_cached_stream_db(db::SQLite.DB, id::Int, stream_type::String)
    result = SQLite.DBInterface.execute(db, "SELECT data FROM streams WHERE activity_id = ? AND stream_type = ?", (id, stream_type))
    for row in result
        val = row[1]
        if !ismissing(val)
            return JSON3.read(val, Dict{Symbol, Any})
        end
    end
    return missing
end

function get_cached_ids_db(db::SQLite.DB)
    result = SQLite.DBInterface.execute(db, "SELECT id FROM activities")
    ids = Int[]
    for row in result
        val = row[1]
        if !ismissing(val)
            push!(ids, Int(val))
        end
    end
    return ids
end

function has_cached_streams(db::SQLite.DB, id::Int)
    result = SQLite.DBInterface.execute(db, "SELECT 1 FROM streams WHERE activity_id = ? LIMIT 1", (id,))
    has_any = false
    for row in result
        has_any = true
    end
    return has_any
end
