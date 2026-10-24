"""
    CRDSClient

A Julia client for STScI's Calibration Reference Data System (CRDS): which reference files apply
to an exposure, and those files in a local cache.  Rules (`.pmap`/`.imap`/`.rmap`) are evaluated
locally once cached, so repeat lookups work offline; the cache layout and environment variables
(`CRDS_PATH`, `CRDS_SERVER_URL`, `CRDS_CONTEXT`, `CRDS_MODE`, ...) are those of the Python `crds`
client, so both can share one cache.
"""
module CRDSClient

import Dates
import Downloads
using FileWatching: Pidfile
import JSON
import SHA
using Scratch: @get_scratch!

export best_references, get_references, resolve_context, required_parkeys, flatten_header, server_info,
       cache_paths, reference_path, CRDSError, CRDSLookupError, CRDSOfflineError

include("config.jl")
include("literal.jl")
include("network.jl")
include("selectors.jl")
include("serverinfo.jl")
include("jwst.jl")
include("mappings.jl")
include("api.jl")

end # module CRDSClient
