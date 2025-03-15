using Revise
using StravaConnect

u = setup_user("data/user.json");

df = get_activity_list(u)

reduce_subdicts!(df)
fill_dicts!(df)

act = [get_activity(x[:id], u) for x in df[end-5:end]]

reduce_subdicts!(act)
fill_dicts!(act)

decode_polyline.([x[:map_summary_polyline] for x in df])


