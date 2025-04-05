using StravaConnect
# using DataFrames

u = setup_user();

df = get_activity_list(u)

reduce_subdicts!(df)
fill_dicts!(df)

# DataFrame(df)

samples = [first(df), rand(df), rand(df), last(df)] # Sample a few random activities for testing

act = [get_activity(x[:id], u; verbose = true) for x in samples]

reduce_subdicts!(act)
fill_dicts!(act)

# DataFrame(act[1])
