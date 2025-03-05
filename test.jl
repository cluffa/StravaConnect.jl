using StravaConnect

u = setup_user("data/user.json");

activities = get_activity_list(u)

x = get_activity(activities.id[end], u)

x.heartrate

activities.start_date_local[end]

activities |> keys

minimum(activities.start_date_local)

unique(activities.sport_type)

runs = activities.id[contains.(activities.sport_type, "Run")]

distances = activities.distance_mi[contains.(activities.sport_type, "Run")]

sum(distances)

run_data = [get_activity(id, u) for id in last(runs, 10)]
