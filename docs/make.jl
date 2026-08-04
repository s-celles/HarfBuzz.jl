using Documenter
using HarfBuzz

DocMeta.setdocmeta!(HarfBuzz, :DocTestSetup, :(using HarfBuzz); recursive = true)

makedocs(;
    modules = [HarfBuzz],
    sitename = "HarfBuzz.jl",
    authors = "Sébastien Celles",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://s-celles.github.io/HarfBuzz.jl",
        edit_link = "main",
        inventory_version = "0.1",
    ),
    pages = [
        "Home" => "index.md",
        "API" => [
            "Types" => "api/types.md",
            "Shaping" => "api/shaping.md",
            "Font queries" => "api/queries.md",
        ],
    ],
)

deploydocs(;
    repo = "github.com/s-celles/HarfBuzz.jl.git",
    push_preview = true,
)