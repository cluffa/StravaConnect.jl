using StravaConnect
using Dates

# This script demonstrates how to fetch a small amount of data from Strava
# to avoid hitting rate limits.

# 1. Setup user (will use existing user.json or trigger OAuth)
u = get_or_setup_user()

# 2. Get activity list (caching is automatic)
# We can limit the number of activities by providing an 'after' timestamp.
# For example, only fetch activities from the last 7 days.
seven_days_ago = Int(floor(time() - 7 * 24 * 3600))
@info "Fetching activities from the last 7 days..."

# Note: get_activity_list doesn't currently support passing 'after' directly 
# as an argument to the high-level function, it uses the cached mtime.
# To force a specific 'after' for a small fetch, we could use the internal api,
# but the easiest way is to let the cache handle it.

list = get_activity_list(u)
@info "Found $(length(list)) total activities in cache/API."

# 3. Fetch details for only the most recent 5 activities
# This prevents hitting the daily rate limit (1000 requests) if you have many activities.
recent_activities = sort(list, by=x -> x[:start_date], rev=true)[1:min(5, end)]

@info "Fetching detailed streams for $(length(recent_activities)) recent activities..."

for act in recent_activities
    id = act[:id]
    name = act[:name]
    @info "Loading $name (ID: $id)..."
    
    # get_activity automatically caches to SQLite
    data = get_activity(id, u; verbose=true)
    
    if haskey(data, :time)
        @info "  Loaded $(length(data[:time][:data])) data points."
    end
end

@info "Done! Data is cached in SQLite for future use."
