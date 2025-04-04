using StravaConnect
# using DataFrames

u = setup_user();

df = get_activity_list(u)

reduce_subdicts!(df)
fill_dicts!(df)

# DataFrame(df)

act = [get_activity(x[:id], u; verbose = true) for x in df[end-2:end]]

reduce_subdicts!(act)
fill_dicts!(act)

# DataFrame(act[1])
