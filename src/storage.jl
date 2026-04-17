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
    
    # Activities table: id, metadata (json), mtime
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS activities (
            id INTEGER PRIMARY KEY,
            metadata TEXT,
            mtime INTEGER
        )
    """)
    
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
    SQLite.execute(db, "INSERT OR REPLACE INTO activities (id, metadata, mtime) VALUES (?, ?, ?)", (id, metadata_json, mtime))
end

function save_stream!(db::SQLite.DB, activity_id::Int, stream_type::String, data::Dict)
    data_json = JSON3.write(data)
    SQLite.execute(db, "INSERT OR REPLACE INTO streams (activity_id, stream_type, data) VALUES (?, ?, ?)", (activity_id, stream_type, data_json))
end

function get_cached_metadata_all(db::SQLite.DB)
    results = SQLite.DBInterface.execute(db, "SELECT metadata FROM activities")
    out = Dict{Symbol, Any}[]
    for row in results
        push!(out, JSON3.read(row.metadata, Dict{Symbol, Any}))
    end
    return out
end

function get_cached_mtime(db::SQLite.DB)
    result = SQLite.DBInterface.execute(db, "SELECT value FROM cache_metadata WHERE key = 'mtime'")
    for row in result
        return parse(Int, row.value)
    end
    return 0
end

function set_cached_mtime!(db::SQLite.DB, mtime::Int)
    SQLite.execute(db, "INSERT OR REPLACE INTO cache_metadata (key, value) VALUES ('mtime', ?)", (string(mtime),))
end

function get_cached_activity_db(db::SQLite.DB, id::Int)
    result = SQLite.DBInterface.execute(db, "SELECT metadata FROM activities WHERE id = ?", (id,))
    for row in result
        activity = JSON3.read(row.metadata, Dict{Symbol, Any})
        
        # Load streams
        streams = SQLite.DBInterface.execute(db, "SELECT stream_type, data FROM streams WHERE activity_id = ?", (id,))
        for s_row in streams
            activity[Symbol(s_row.stream_type)] = JSON3.read(s_row.data, Dict{Symbol, Any})
        end
        return activity
    end
    return missing
end

function get_cached_stream_db(db::SQLite.DB, id::Int, stream_type::String)
    result = SQLite.DBInterface.execute(db, "SELECT data FROM streams WHERE activity_id = ? AND stream_type = ?", (id, stream_type))
    for row in result
        return JSON3.read(row.data, Dict{Symbol, Any})
    end
    return missing
end

function get_cached_ids_db(db::SQLite.DB)
    result = SQLite.DBInterface.execute(db, "SELECT id FROM activities")
    return [Int(row.id) for row in result]
end

function has_cached_streams(db::SQLite.DB, id::Int)
    result = SQLite.DBInterface.execute(db, "SELECT 1 FROM streams WHERE activity_id = ? LIMIT 1", (id,))
    return !isempty(result)
end
