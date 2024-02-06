### A Pluto.jl notebook ###
# v0.19.38

using Markdown
using InteractiveUtils

# ╔═╡ ef6f15e4-c481-11ee-100c-7d6413c59795
begin
    import Pkg
    Pkg.activate(Base.current_project())
    Pkg.instantiate()
	Pkg.resolve()
	
	using Plots, DataFrames, StravaConnect
end

# ╔═╡ c7f5017e-3d40-41de-a5f1-02bede6e6ee6
user = setup_user("../.tokens", "../.secret");

# ╔═╡ e5169776-f0a1-4386-b2fc-56d75d96ad6d
activities = get_all_activities(user)

# ╔═╡ 6b1ff7ce-fb95-4067-b9b4-bf1bc302a145
activity = get_activity("10167358861", user)

# ╔═╡ a16267df-c627-474c-b5b5-1881c1d28c26
plot(reverse.(activity.latlng), ratio = 1)

# ╔═╡ Cell order:
# ╠═ef6f15e4-c481-11ee-100c-7d6413c59795
# ╠═c7f5017e-3d40-41de-a5f1-02bede6e6ee6
# ╠═e5169776-f0a1-4386-b2fc-56d75d96ad6d
# ╠═6b1ff7ce-fb95-4067-b9b4-bf1bc302a145
# ╠═a16267df-c627-474c-b5b5-1881c1d28c26
