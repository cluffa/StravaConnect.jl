using StravaConnect
using DataFrames

u = setup_user();

df = get_activity_list(u)

reduce_subdicts!(df)
fill_dicts!(df)

df = DataFrame(df) 

display(df);

act = [get_activity(x[:id], u) for x in df[end-5:end]]

reduce_subdicts!(act)
fill_dicts!(act)

act_df = DataFrame(act[1])
display(act_df)
