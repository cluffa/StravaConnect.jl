# StravaConnect.jl  
## WIP Functionality may change without notice

This is for personal use only and I do not plan on supporting it.

Set these environment variables
```
STRAVA_CLIENT_ID
STRAVA_CLIENT_SECRET
```

### Examples

```
pkg> add https://github.com/cluffa/StravaConnect.jl.git
```

```julia
using StravaConnect

get_or_setup_user();

list = get_activity_list() .|> reduce_subdicts! |> fill_dicts!;

id = list[end][:id]
id = get_cached_activity_ids()[1]

get_activity(id)

get_cached_activity(id)

get_cached_activity_stream(id, :latlng)
```
