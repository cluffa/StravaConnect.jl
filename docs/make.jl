using Documenter
using StravaConnect

makedocs(
    sitename = "StravaConnect.jl",
    format = Documenter.HTML(),
    modules = [StravaConnect],
    pages = [
        "Home" => "index.md",
    ]
)

deploydocs(
    repo = "github.com/cluffa/StravaConnect.jl.git",
    devbranch = "main"
)
