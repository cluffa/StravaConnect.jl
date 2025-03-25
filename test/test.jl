using Revise
using StravaConnect

u = setup_user("user.json");

df = get_activity_list(u)

reduce_subdicts!(df)
fill_dicts!(df)

act = [get_activity(x[:id], u) for x in df[end-5:end]]

reduce_subdicts!(act)
fill_dicts!(act)
