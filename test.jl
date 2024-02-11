using StravaConnect
u = setup_user();

activities = get_all_activities(u);

activity_data = [get_activity(id, u; temp_dir = "./data/") for id in activities.id];
