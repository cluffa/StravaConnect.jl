using StravaConnect
u = setup_user();

activities = get_all_activities(u);

unique(activities.sport_type)

runs = activities.id[contains.(activities.sport_type, "Run")]

run_data = [get_activity(id, u) for id in runs]
