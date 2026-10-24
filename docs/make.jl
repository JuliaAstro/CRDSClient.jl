using CRDSClient
using Documenter
using Documenter.Remotes: GitHub

makedocs(;
    modules = [CRDSClient],
    authors = "Chris Garling",
    repo = GitHub("JuliaAstro", "CRDSClient.jl"),
    sitename = "CRDSClient.jl",
    format = Documenter.HTML(; canonical = "https://juliaastro.org/CRDSClient/stable/", edit_link = "main"),
    pages = ["Home" => "index.md", "API" => "api.md"],
    checkdocs = :exports,
)

deploydocs(;
    repo = "github.com/JuliaAstro/CRDSClient.jl.git",
    devbranch = "main",
    push_preview = true,
    versions = ["stable" => "v^", "v#.#"],
)
