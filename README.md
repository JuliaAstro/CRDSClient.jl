# CRDSClient.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliaastro.org/CRDSClient/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliaastro.org/CRDSClient.jl/dev/)
[![CI](https://github.com/JuliaAstro/CRDSClient.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaAstro/CRDSClient.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/JuliaAstro/CRDSClient.jl/graph/badge.svg)](https://codecov.io/gh/JuliaAstro/CRDSClient.jl)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Julia client for STScI's [Calibration Reference Data System](https://hst-crds.stsci.edu/static/users_guide/index.html)
(CRDS): which reference files (ePSFs, flats, darks, pixel area maps, ...) apply to an exposure, and those
files in a local cache.

- **Local rule evaluation.** Once a context's rule files (`.pmap` → `.imap` → `.rmap`) are cached, best
  references are computed locally, so repeat lookups work offline. The evaluator is a port of the Python
  `crds` client's `Match`/`UseAfter`/`VersionAfter` selection. For Roman and JWST it agrees with the CRDS
  servers on every answer tested (Roman: 604,500 header × reference-type answers across all 68 historical
  contexts; JWST: see `test/server_compare.jl`).
- **Shares the Python client's cache and settings.** Same folder layout and environment variables
  (`CRDS_PATH`, `CRDS_SERVER_URL`, `CRDS_CONTEXT`, `CRDS_MODE`, ...), so both clients use one cache.
- **Any context.** A literal context (`"roman_0058.pmap"`), `"latest"`/`"operational"`/`"edit"`/`"build"`,
  or a date (`"roman-2026-10-01"`: the context that was current then).
- **Checked downloads, safe concurrency.** Files are checked against the server's size and sha1, written
  to a temporary file and renamed into place, and locked per file across threads and processes, so a
  file requested by many workers at once is downloaded once.
- **Clear errors.** A failed lookup names the reference type, the header parameter and its value, and the
  values the rules list.

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

## Configuration

| Variable | What it means |
| --- | --- |
| `CRDS_PATH` | Cache root: `mappings/<obs>/`, `references/<obs>/<instrument>/`, `config/<obs>/` |
| `CRDS_PATH_SINGLE`, `CRDS_MAPPATH[_SINGLE]`, `CRDS_REFPATH[_SINGLE]`, `CRDS_CFGPATH[_SINGLE]`, `CRDS_DEFAULT_CACHE` | The Python client's other cache variables, same precedence. With none set, a Julia scratch space (`cache_paths(obs)` shows where) |
| `CRDS_SERVER_URL` | Server; default `https://{hst,jwst,roman}-crds.stsci.edu`. The server's observatory is checked |
| `CRDS_CONTEXT` | Default context (else `"latest"`) |
| `CRDS_MODE` | Default `mode`: `auto`, `local`, `remote` |
| `CRDS_ALLOW_BAD_RULES`, `CRDS_ALLOW_BAD_REFERENCES` | Use files CRDS has marked bad (warning instead of error) |
| `CRDS_OBSERVATORY` | Observatory when it cannot be told from the context or header |
| `CRDS_READONLY_CACHE` | The cache is read-only, e.g. one shared on a cluster: nothing is downloaded or written, and its stored server information is used however old (see below) |

Modes: `:auto` evaluates rules locally (Roman, JWST) and asks the server only for rules this package does
not evaluate; `:local` never contacts the server; `:remote` lets the server choose. HST best references
always come from the server: its rules contain Python expressions and the Python client applies
instrument-specific selection hooks for it, neither of which is reproduced here, so an HST lookup in
`:local` mode or with the server unreachable is a `CRDSOfflineError`. Contexts, rule files,
`required_parkeys` and checked, cached downloads (Python's folder layout) work for HST as for Roman and JWST.

## Contexts

A context (`.pmap`) fixes every rule; each delivery of new reference files makes a new one. `context`
accepts a literal name (`"roman_0072.pmap"`), a date (`"jwst-2026-10-01"`, `"2026-10-01T12:00:00"`: the
context that was active then, from the server's history) or one of the server's named contexts:

| Name | Meaning |
| --- | --- |
| `"latest"` (default) | The newest context the server has activated: the most recent reference deliveries |
| `"edit"` | The context new deliveries are being added to (usually the same as `latest`) |
| `"operational"` | The context the observatory's archive processing currently uses |
| `"build"` | The context matched to the current calibration pipeline release |

These can differ: on 2026-10-24 JWST had `latest` = `edit` = `jwst_1598.pmap` and `operational` = `build`
= `jwst_1584.pmap`; Roman had `latest` = `edit` = `operational` = `roman_0077.pmap` and `build` =
`roman_0041.pmap`. To use the references the archive's processed files were made with, pass
`context = "operational"`; to make results reproducible, pass a literal `.pmap` name. Names may be prefixed
with the observatory (`"jwst-latest"`); `resolve_context` shows what a name means now.

## Differences from the Python `crds` client

- **The default context is `"latest"` for every observatory.** For JWST the Python client defaults to the
  "build" context that matches the installed `jwst` calibration pipeline; this package is not tied to a
  pipeline. Pass `context` (or set `CRDS_CONTEXT`) to pin one.
- **"All reference types" means every type of the instrument.** With no `reftypes`, the Python client
  narrows JWST lookups to the types its pipeline steps need for the exposure type (from files bundled with
  it); here every type in the instrument's `.imap` is looked up.
- **Download locks.** Both clients download to a temporary file and rename it into place, so neither ever
  sees a partial file in a shared cache. Their locks are separate (this package: `.<file>.crdsclient-lock`,
  a `FileWatching` pidfile; Python: `<file>.lock` from the `filelock` package), so they do not wait for
  each other: a file both fetch at the same moment is downloaded twice, never corrupted.
- **JWST headers** may use data-model keys (`META.EXPOSURE.TYPE`) or FITS keywords (`EXP_TYPE`), translated
  with a table generated from the `stdatamodels` schema (`gen/jwst_fits_keywords.py`); a data-model key wins
  over a FITS keyword for the same field. `src/jwst.jl` lists every JWST-specific dependency and how to
  update it.

**Offline.** The server is contacted only when something is missing: rule files of a context not yet
cached, a reference file, or server information (current contexts, bad files) older than
`CRDSClient.SERVER_INFO_MAX_AGE[]` (24 h). A failure to connect (capped at `CRDSClient.CONNECT_TIMEOUT[]`,
5 s) marks the server unreachable for the session, so later calls work from the cache without waiting
(`CRDSClient.reset_offline!()` to retry).

**Shared and read-only caches.** A cache filled once and read by many jobs (e.g. on a cluster) can be
marked with `CRDS_READONLY_CACHE=1`, as for the Python client: files it lacks are an error rather than
a download, nothing is written to it, and the server information stored in it is used however old, so
`"latest"` means the newest context the cache was filled with. Lookups may still ask the server (HST,
`:remote`), which needs no writes. Without the setting, a cache that turns out not to be writable costs
a warning when server information is refreshed, not the lookup.

## Acknowledgements

The rule evaluation, value handling and cache conventions are translated from STScI's Python
[`crds`](https://github.com/spacetelescope/crds) client, and the JWST keyword table is generated from
[`stdatamodels`](https://github.com/spacetelescope/stdatamodels); their copyright notices and licenses
(BSD 3-clause, AURA) are in `THIRD_PARTY_NOTICES.md`. CRDSClient.jl is an independent project, not
endorsed by STScI or AURA.

Developed with AI assistance (Claude).

## Tests

`julia --project -e 'using Pkg; Pkg.test()'` runs offline unit tests (parser, matchers, selectors,
cache paths, checked and concurrent downloads), then live comparisons with the Roman and JWST servers:
300 random headers per context, drawn from the context's own rules, sent in one batched request and
compared with local evaluation (`test/server_compare.jl`), and an HST lookup and download through the
server. The live tests use the normal cache, so rule
files are downloaded on the first run only; an unreachable server, or `CRDSCLIENT_SKIP_ONLINE=1`, skips them.
