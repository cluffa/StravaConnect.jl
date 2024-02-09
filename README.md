# StravaConnect.jl  
## WIP

```julia
using StravaConnect
user = setup_user()

refresh_if_needed!(user)
activities = get_all_activities(u)
activity = get_activity(ACTIVITY_ID, u)
```

`get_all_activities` returns `NamedTuple` of:  
```julia
id = Int64[]
name = String[]
distance = Float64[]
distance_mi = Float64[]
start_date_local = DateTime[]
elapsed_time = Float64[]
sport_type = String[]
```

`get_activity` returns `NamedTuple` of:  
```julia
time = Int64[]
distance = Float64[]
distance_mi = Float64[]
latlng = Tuple{Float64, Float64}[]
altitude = Float64[]
altitude_ft = Float64[]
velocity_smooth = Float64[]
heartrate = Int64[]
cadence = Int64[]
watts = Float64[]
temp = Int64[]
temp_f = Float64[]
moving = Bool[]
grade_smooth = Float64[]
```  
only when applicable, otherwise vectors are empty.
