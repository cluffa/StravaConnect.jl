using StravaConnect

get_or_setup_user();

list = get_activity_list() .|> reduce_subdicts! |> fill_dicts!;

id = list[end][:id]
id = get_cached_activity_ids()[1]

get_activity(id) 

get_cached_activity(id)

get_cached_activity_stream(id, :latlng)
