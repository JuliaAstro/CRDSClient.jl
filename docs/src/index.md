# CRDSClient.jl

A Julia client for STScI's [Calibration Reference Data System](https://hst-crds.stsci.edu/static/users_guide/index.html)
(CRDS): which reference files (ePSFs, flats, darks, pixel area maps, ...) apply to an exposure, and those
files in a local cache. It supports Roman, JWST and HST, and shares its cache and settings with the
Python `crds` client.

## Installation

```julia
using Pkg
Pkg.add("CRDSClient")
```

## Quick start

```julia
using CRDSClient

header = Dict("ROMAN.META.INSTRUMENT.NAME" => "WFI", "ROMAN.META.INSTRUMENT.DETECTOR" => "WFI02",
              "ROMAN.META.INSTRUMENT.OPTICAL_ELEMENT" => "F087",
              "ROMAN.META.EXPOSURE.START_TIME" => "2026-10-02T03:25:39.356",
              "ROMAN.META.EXPOSURE.TYPE" => "WFI_IMAGE")

best_references(header; context = "roman_0072.pmap", reftypes = ["epsf", "area"])
# Dict("epsf" => "roman_wfi_epsf_0266.asdf", "area" => "roman_wfi_area_0034.asdf")

paths = get_references(header; context = "roman_0072.pmap", reftypes = ["epsf", "area"])  # downloads if needed
fetch_reference("roman_wfi_epsf_0266.asdf")   # one file by name, e.g. as a header records it
fetch_reference("jref\$72m18219j_ccd.fits")   # HST names with their IRAF prefix work too

required_parkeys("roman_0072.pmap"; reftypes = ["epsf"])   # the header keys the rules read
resolve_context("roman-2026-10-01")                          # "roman_0072.pmap"
```

From a Roman L2 file's metadata tree (e.g. ASDF.jl's `af["roman"]["meta"]`):
`best_references(flatten_header(meta; prefix = "ROMAN.META"); context = ...)`.

JWST headers may use data-model keys (`META.EXPOSURE.TYPE`) or FITS keywords (`EXP_TYPE`).

## Modes

Every function that may contact the server takes a `mode` keyword:

| Mode | What it means |
| --- | --- |
| `:auto` (default) | Roman and JWST rules are evaluated locally from the cached rule files (downloaded when missing); HST lookups and anything not evaluated locally go to the server |
| `:local` | Never contact the server: work from the cache only |
| `:remote` | The server chooses the best references |

## Contexts

A context (`.pmap`) fixes every rule; each delivery of new reference files makes a new one. `context`
accepts a literal name (`"roman_0072.pmap"`), a date (`"jwst-2026-10-01"`: the context that was active
then) or one of the server's named contexts:

| Name | Meaning |
| --- | --- |
| `"latest"` (default) | The newest context the server has activated |
| `"edit"` | The context new deliveries are being added to (usually the same as `latest`) |
| `"operational"` | The context the observatory's archive processing currently uses |
| `"build"` | The context matched to the current calibration pipeline release |

Pass a literal `.pmap` name to make results reproducible; [`resolve_context`](@ref) shows what a name
means now.

## Configuration

| Variable | What it means |
| --- | --- |
| `CRDS_PATH` | Cache root: `mappings/<obs>/`, `references/<obs>/<instrument>/`, `config/<obs>/` |
| `CRDS_PATH_SINGLE`, `CRDS_MAPPATH[_SINGLE]`, `CRDS_REFPATH[_SINGLE]`, `CRDS_CFGPATH[_SINGLE]`, `CRDS_DEFAULT_CACHE` | The Python client's other cache variables, same precedence. With none set, a Julia scratch space ([`cache_paths`](@ref) shows where) |
| `CRDS_SERVER_URL` | Server; default `https://{hst,jwst,roman}-crds.stsci.edu` |
| `CRDS_CONTEXT` | Default context (else `"latest"`) |
| `CRDS_MODE` | Default `mode`: `auto`, `local`, `remote` |
| `CRDS_ALLOW_BAD_RULES`, `CRDS_ALLOW_BAD_REFERENCES` | Use files CRDS has marked bad (warning instead of error) |
| `CRDS_OBSERVATORY` | Observatory when it cannot be told from the context or header |
| `CRDS_READONLY_CACHE` | The cache is read-only, e.g. one shared on a cluster: nothing is downloaded or written |
