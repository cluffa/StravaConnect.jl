# StravaConnect.jl  
## WIP Functionality may change without notice

Set these environment variables
```
STRAVA_CLIENT_ID
STRAVA_CLIENT_SECRET
```

### Examples
```julia
using StravaConnect
# loads/saves to file if path provided
user = setup_user("/data/user.json") 

activities = get_activity_list(u)

id = activities[end][:id]

activity = get_activity(id, u)

# Helper functions
# flattens subdicts into current dict, useful for DataFrame(Vector{Dict})
# d[:map][:summary_polyline] becomes d[:map_summary_polyline]
reduce_subdicts!(Vector{Dict} or Dict)

# gives each dict in a vector all keys, useful for DataFrame(Vector{Dict})
fill_dicts!(Vector{Dict})

# Install https://github.com/cluffa/Polyline.jl
# decodes Google Polyline, activities[:map][:summary_polyline], into lat long points
decode_polyline(Tuple{Float, Float})

# encodes GPS points into Google Polyline encoded string
encode_polyline(Vector{Tuple{Float, Float}})
```