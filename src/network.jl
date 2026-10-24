# Talking to the CRDS server: JSON-RPC calls and checked file downloads.
#
# Offline: a failure to *connect* (DNS, refused, connect timeout) marks the server unreachable
# for the rest of the session, so an offline session waits for CONNECT_TIMEOUT at most once per
# server; `reset_offline!()` clears that.  Other failures (HTTP errors, a stalled transfer) are
# retried and do not mark the server offline.
#
# Concurrency: every download of a cache file holds a lock for that file, within the process (a
# ReentrantLock per destination) and across processes (a pidfile `.<file>.crdsclient-lock` next to
# it, which FileWatching clears when its owner has died); whoever gets the lock second finds the
# file and returns.  The data go to a `.part` file unique to the process and task and are renamed
# into place, so a reader never sees a partial file.
#
# The Python crds client (14+) locks downloads with an OS lock (the `filelock` package) on
# `<file>.lock` and deletes that file when done; `crds sync --clear-locks` deletes every `*.lock` in
# the cache.  Our lock has its own name so the two never interfere: if both clients fetch the same
# file at the same moment both download it, and either result is complete (both rename atomically).

const UNREACHABLE = Set{String}()      # server URLs that could not be reached this session
const NET_LOCK = ReentrantLock()

"Forget which servers were unreachable this session, so the next need for one tries again."
reset_offline!() = lock(() -> empty!(UNREACHABLE), NET_LOCK)

_unreachable(obs) = lock(() -> server_url(obs) in UNREACHABLE, NET_LOCK)

"Whether the server of `obs` may be contacted in `mode`: not `:local`, and not found unreachable."
can_contact(obs, mode) = mode !== :local && !_unreachable(obs)

function _downloader()
    d = Downloads.Downloader()
    d.easy_hook = (easy, info) -> Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_CONNECTTIMEOUT, round(Int, CONNECT_TIMEOUT[]))
    return d
end

# curl codes 5, 6 (proxy/host not resolved), 7 (could not connect), and 28 (timeout) only while
# connecting: the server is unreachable.  A timeout mid-transfer is not.
_is_connection_error(e) = e isa Downloads.RequestError && e.response.status == 0 &&
    (e.code in (5, 6, 7) || (e.code == 28 && occursin(r"[Cc]onnect", e.message)))

function _offline!(obs, e)
    url = server_url(obs)
    first_time = lock(() -> (n = !(url in UNREACHABLE); push!(UNREACHABLE, url); n), NET_LOCK)
    first_time && @warn "CRDS server $url is unreachable ($(e.message)); working from the cache for this session"
    throw(CRDSOfflineError("CRDS server $url is unreachable: $(e.message)"))
end

function _require_contact(obs, what, mode)
    mode === :local && throw(CRDSOfflineError("$what needs the CRDS server, but the mode is local"))
    _unreachable(obs) && throw(CRDSOfflineError("$what needs the CRDS server, which was unreachable earlier this session (CRDSClient.reset_offline!() to retry)"))
end

"""
    rpc(obs, method, params...; mode, tries = 3)

Result of the CRDS JSON-RPC `method` on the server of `obs` (refused in `:local` `mode`).
"""
function rpc(obs, method, params...; mode::Symbol, tries = 3)
    _require_contact(obs, "CRDS $method", mode)
    body = JSON.json(Dict("jsonrpc" => "1.0", "method" => method, "params" => collect(Any, params), "id" => 1))
    for k in 1:tries
        out = IOBuffer()
        resp = try
            Downloads.request(server_url(obs) * "/json/"; method = "POST", input = IOBuffer(body), output = out,
                              headers = ["Content-Type" => "application/json"], timeout = 300, downloader = _downloader())
        catch e
            _is_connection_error(e) && _offline!(obs, e)
            (e isa Downloads.RequestError && k < tries) || rethrow()
            @warn "CRDS $method failed (try $k of $tries); retrying" exception = e
            sleep(2k)
            continue
        end
        if resp.status >= 500 && k < tries
            @warn "CRDS $method: HTTP $(resp.status) (try $k of $tries); retrying"
            sleep(2k)
            continue
        end
        resp.status == 200 || throw(CRDSError("CRDS $method: HTTP $(resp.status) from $(server_url(obs))"))
        r = JSON.parse(String(take!(out)))
        err = r["error"]
        err === nothing || throw(CRDSError("CRDS $method: " * (err isa AbstractDict ? string(get(err, "message", err)) : string(err))))
        return r["result"]
    end
end

# Move `tmp` onto `dest` atomically: `dest` is the old file or the new one, never missing (POSIX
# rename(2), as the Python client's os.replace; `mv(...; force = true)` on Julia 1.10 deletes
# `dest` first).  If the rename fails but `dest` exists (Windows refuses to replace a file another
# process has open), another client has put a complete copy there: drop ours.
function _replace(tmp, dest)
    try
        Base.Filesystem.rename(tmp, dest)
    catch e
        (e isa Base.IOError && isfile(dest)) || rethrow()
        rm(tmp; force = true)
    end
    return dest
end

"sha1 of a file, as hex (the checksum CRDS lists)."
sha1_file(path) = open(io -> bytes2hex(SHA.sha1(io)), path)

const FILE_LOCKS = Dict{String, ReentrantLock}()
const FILE_LOCKS_LOCK = ReentrantLock()
_file_lock(path) = lock(() -> get!(ReentrantLock, FILE_LOCKS, path), FILE_LOCKS_LOCK)

"Run `f()` holding the in-process and cross-process locks of cache file `dest`."
function with_file_lock(f, dest)
    mkpath(dirname(dest))
    lock(_file_lock(dest)) do
        Pidfile.mkpidlock(f, joinpath(dirname(dest), "." * basename(dest) * ".crdsclient-lock"); stale_age = 60)
    end
end

"""
    fetch_file(obs, url, dest; mode, size = nothing, sha1sum = nothing, tries = 3)

Download `url` to `dest` unless another thread or process already has: under `dest`'s locks,
to a `.part` file next to it, with its size and sha1 checked when given, then renamed into place.
Retries transient failures; an unreachable server is not retried.
"""
function fetch_file(obs, url, dest; mode::Symbol, size = nothing, sha1sum = nothing, tries = 3)
    with_file_lock(dest) do
        isfile(dest) && return dest                     # fetched while we waited for the lock
        _require_contact(obs, "downloading $(basename(dest))", mode)
        @info "CRDS: downloading $(basename(dest))" * (size === nothing ? "" : " ($(round(size / 1e6, digits = 1)) MB)")
        part = joinpath(dirname(dest), ".$(basename(dest)).$(getpid()).$(objectid(current_task())).part")
        for k in 1:tries
            try
                Downloads.download(url, part; timeout = 3600, downloader = _downloader())
                got = filesize(part)
                size === nothing || got == size || throw(CRDSError("$(basename(dest)): downloaded $got bytes, server lists $size"))
                if sha1sum !== nothing && !(sha1sum in ("", "none"))
                    h = sha1_file(part)
                    h == sha1sum || throw(CRDSError("$(basename(dest)): sha1 $h does not match the server's $sha1sum"))
                end
                return _replace(part, dest)
            catch e
                rm(part; force = true)
                _is_connection_error(e) && _offline!(obs, e)
                k == tries && rethrow()
                @warn "download of $(basename(dest)) failed (try $k of $tries); retrying" exception = e
                sleep(2k)
            end
        end
    end
end

"Write `text` to `path` atomically (a unique temporary file renamed into place)."
function write_atomic(path, text)
    mkpath(dirname(path))
    tmp = joinpath(dirname(path), ".$(basename(path)).$(getpid()).$(objectid(current_task())).tmp")
    write(tmp, text)
    return _replace(tmp, path)
end

# Server's size and sha1 of `names` (one RPC), as Dict(name => (size, sha1sum)).
function file_info(obs, names, mode)
    info = rpc(obs, "get_file_info_map", obs, collect(names), ["size", "sha1sum"]; mode)
    return Dict(String(n) => (parse(Int, string(v["size"])), string(v["sha1sum"])) for (n, v) in info)
end
