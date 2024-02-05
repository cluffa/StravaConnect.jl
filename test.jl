using StravaConnect
using DataFrames
using Dates

u = setup_user()

activities = get_all_activities(u)
activity = get_activity("10690510371", u)
