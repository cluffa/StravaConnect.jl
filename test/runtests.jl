using Revise
using StravaConnect

get_or_setup_user();

list = get_activity_list() # .|> reduce_subdicts! |> fill_dicts! |> DataFrame;
get_cached_activity_list()

id = list[end][:id]
ids = get_cached_activity_ids()

get_activity(id)
get_cached_activity(id)

get_activity_stream(id, :time)
get_cached_activity_stream(id, :time)
