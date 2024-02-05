using StravaConnect
using DataFrames
using Dates

user = setup_user()

get_activities(user)