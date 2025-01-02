using StravaConnect
u = setup_user();

activities = get_all_activities(u);

activities.id |> typeof

activity = get_activity(last(activities.id), u; temp_dir = "./data/")

activity |> typeof