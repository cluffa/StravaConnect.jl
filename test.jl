using Revise
using StravaConnect
using HTTP

u = setup_user("data/user.json");

activities = get_activity_list(u);

x = get_activity(activities.id[1], u; force_update = true);
