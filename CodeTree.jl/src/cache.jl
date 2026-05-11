# SQLite cache for CodeTree.jl (R24–R28).
#
# Cache location: <root>/.7aigent/code_tree/index.db
# Schema:
#   cache_meta — compatibility token for invalidating stale caches
#   files      — (path PK, hash, commit_hash)
#   code       — all db.code columns plus a `file` key for fast per-file access
#   symbols    — (file, node_id, symbol, kind)

using DBInterface
using Tables

const _CACHE_SUBDIR = joinpath(".7aigent", "code_tree")
const _CACHE_FILE   = "index.db"
const _CACHE_COMPAT_KEY = "compat_version"
const _CACHE_COMPAT_VERSION = "3"

# ---------------------------------------------------------------------------
# Open / create
# ---------------------------------------------------------------------------

"""
    _cache_path(root_path) -> String

Absolute path to the SQLite cache database for the given codebase root.
"""
function _cache_path(root_path::String)::String
    return joinpath(root_path, _CACHE_SUBDIR, _CACHE_FILE)
end

"""
    _open_or_create_cache(root_path) -> SQLite.DB

Open the SQLite cache (creating it if absent) and ensure the schema exists.
"""
function _open_or_create_cache(root_path::String)::SQLite.DB
    dir = joinpath(root_path, _CACHE_SUBDIR)
    isdir(dir) || mkpath(dir)
    db = SQLite.DB(_cache_path(root_path))
    _ensure_cache_compatible!(db)
    _init_cache_schema!(db)
    _set_cache_meta!(db, _CACHE_COMPAT_KEY, _CACHE_COMPAT_VERSION)
    return db
end

function _init_cache_schema!(db::SQLite.DB)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS cache_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS files (
            path        TEXT PRIMARY KEY,
            hash        TEXT NOT NULL,
            commit_hash TEXT
        )
    """)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS code (
            file          TEXT NOT NULL,
            id            TEXT NOT NULL,
            parent        TEXT,
            depth         INTEGER NOT NULL,
            sibling_order INTEGER NOT NULL,
            kind          TEXT NOT NULL,
            name          TEXT NOT NULL,
            qname         TEXT,
            language      TEXT,
            summary       TEXT,
            source        TEXT,
            signature     TEXT,
            line_start    INTEGER,
            line_end      INTEGER,
            n_lines       INTEGER,
            n_children    INTEGER NOT NULL,
            PRIMARY KEY (file, id)
        )
    """)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS symbols (
            file    TEXT NOT NULL,
            node_id TEXT NOT NULL,
            symbol  TEXT NOT NULL,
            kind    TEXT NOT NULL
        )
    """)
    DBInterface.execute(db,
        "CREATE INDEX IF NOT EXISTS idx_code_file    ON code(file)")
    DBInterface.execute(db,
        "CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file)")
end

function _ensure_cache_compatible!(db::SQLite.DB)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS cache_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)
    cached_version = _get_cache_meta(db, _CACHE_COMPAT_KEY)
    cached_version == _CACHE_COMPAT_VERSION && return

    DBInterface.execute(db, "BEGIN")
    try
        DBInterface.execute(db, "DROP TABLE IF EXISTS symbols")
        DBInterface.execute(db, "DROP TABLE IF EXISTS code")
        DBInterface.execute(db, "DROP TABLE IF EXISTS files")
        DBInterface.execute(db, "DROP TABLE IF EXISTS cache_meta")
        DBInterface.execute(db, "COMMIT")
    catch
        DBInterface.execute(db, "ROLLBACK")
        rethrow()
    end
end

function _get_cache_meta(db::SQLite.DB, key::String)::Union{String,Nothing}
    result = DBInterface.execute(db, "SELECT value FROM cache_meta WHERE key = ?", [key])
    rows = collect(result)
    isempty(rows) && return nothing
    val = Tables.getcolumn(rows[1], :value)
    (isnothing(val) || ismissing(val)) && return nothing
    return String(val)
end

function _set_cache_meta!(db::SQLite.DB, key::String, value::String)
    DBInterface.execute(
        db,
        "INSERT OR REPLACE INTO cache_meta (key, value) VALUES (?, ?)",
        [key, value],
    )
end

# ---------------------------------------------------------------------------
# Read helpers
# ---------------------------------------------------------------------------

"""
    _get_cached_hash(db, path) -> String or nothing

Return the stored SHA-256 hash for `path`, or `nothing` if not cached.
"""
function _get_cached_hash(db::SQLite.DB, path::String)::Union{String,Nothing}
    result = DBInterface.execute(db, "SELECT hash FROM files WHERE path = ?", [path])
    rows = collect(result)
    isempty(rows) && return nothing
    val = Tables.getcolumn(rows[1], :hash)
    (isnothing(val) || ismissing(val)) && return nothing
    return String(val)
end

"""
    _get_all_cached_paths(db) -> Vector{String}

Return all file paths currently stored in the cache.
"""
function _get_all_cached_paths(db::SQLite.DB)::Vector{String}
    result = DBInterface.execute(db, "SELECT path FROM files")
    return [String(Tables.getcolumn(r, :path)) for r in result]
end

"""
    _load_file_rows_from_cache(db, file_rel)
    -> (code_rows, sym_rows) or nothing

Load the cached code and symbol rows for `file_rel`.  Returns `nothing` if the
file is not in the cache.
"""
function _load_file_rows_from_cache(
    db::SQLite.DB,
    file_rel::String,
)::Union{Tuple{Vector{CodeRow}, Vector{NamedTuple}}, Nothing}

    code_result = DBInterface.execute(db, """
        SELECT id, parent, depth, sibling_order, kind, name, qname, language,
               summary, source, signature, line_start, line_end, n_lines, n_children
        FROM code WHERE file = ?
        ORDER BY depth ASC, sibling_order ASC
    """, [file_rel])

    code_rows = CodeRow[]
    for r in code_result
        g(col) = Tables.getcolumn(r, col)
        _s(x)  = (isnothing(x) || ismissing(x)) ? missing : String(x)
        _i(x)  = (isnothing(x) || ismissing(x)) ? missing : Int(x)
        push!(code_rows, CodeRow(
            String(g(:id)),
            _s(g(:parent)),
            Int(g(:depth)),
            Int(g(:sibling_order)),
            String(g(:kind)),
            String(g(:name)),
            _s(g(:qname)),
            _s(g(:language)),
            _s(g(:summary)),
            _s(g(:source)),
            _s(g(:signature)),
            file_rel,
            _i(g(:line_start)),
            _i(g(:line_end)),
            _i(g(:n_lines)),
            Int(g(:n_children)),
        ))
    end
    isempty(code_rows) && return nothing

    # Symbols are currently re-extracted globally by extract_symbols! after
    # loading, so sym_rows from cache are not used by the caller.  They are
    # kept here so the cache round-trips correctly and so a future optimization
    # (skipping global re-extraction for cached files) is straightforward.
    sym_result = DBInterface.execute(db,
        "SELECT node_id, symbol, kind FROM symbols WHERE file = ?", [file_rel])
    sym_rows = NamedTuple{(:node_id, :symbol, :kind), Tuple{String,String,String}}[]
    for r in sym_result
        push!(sym_rows, (
            node_id = String(Tables.getcolumn(r, :node_id)),
            symbol  = String(Tables.getcolumn(r, :symbol)),
            kind    = String(Tables.getcolumn(r, :kind)),
        ))
    end

    return (code_rows, sym_rows)
end

# ---------------------------------------------------------------------------
# Write helpers
# ---------------------------------------------------------------------------

"""
    _upsert_file!(db, path, hash, commit_hash)

Insert or replace the `files` row for `path`.
"""
function _upsert_file!(
    db::SQLite.DB,
    path::String,
    hash::String,
    commit_hash::Union{String,Missing},
)
    ch = ismissing(commit_hash) ? nothing : commit_hash
    DBInterface.execute(db,
        "INSERT OR REPLACE INTO files (path, hash, commit_hash) VALUES (?, ?, ?)",
        [path, hash, ch])
end

"""
    _save_file_rows!(db, file_rel, hash, commit_hash, code_rows, sym_rows)

Replace all cached rows for `file_rel` with the supplied data.
"""
function _save_file_rows!(
    db::SQLite.DB,
    file_rel::String,
    hash::String,
    commit_hash::Union{String,Missing},
    code_rows::Vector{CodeRow},
    sym_rows,
)
    DBInterface.execute(db, "BEGIN")
    try
        DBInterface.execute(db, "DELETE FROM code    WHERE file = ?", [file_rel])
        DBInterface.execute(db, "DELETE FROM symbols WHERE file = ?", [file_rel])
        _upsert_file!(db, file_rel, hash, commit_hash)

        _m(x) = ismissing(x) ? nothing : x
        for r in code_rows
            DBInterface.execute(db, """
                INSERT INTO code
                  (file, id, parent, depth, sibling_order, kind, name,
                   qname, language, summary, source, signature,
                   line_start, line_end, n_lines, n_children)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                file_rel,
                r.id,
                _m(r.parent),
                r.depth,
                r.sibling_order,
                r.kind,
                r.name,
                _m(r.qname),
                _m(r.language),
                _m(r.summary),
                _m(r.source),
                _m(r.signature),
                _m(r.line_start),
                _m(r.line_end),
                _m(r.n_lines),
                r.n_children,
            ])
        end

        for s in sym_rows
            DBInterface.execute(db,
                "INSERT INTO symbols (file, node_id, symbol, kind) VALUES (?,?,?,?)",
                [file_rel, s.node_id, s.symbol, s.kind])
        end
        DBInterface.execute(db, "COMMIT")
    catch
        DBInterface.execute(db, "ROLLBACK")
        rethrow()
    end
end

"""
    _delete_file_from_cache!(db, file_rel)

Remove all cache entries for `file_rel`.
"""
function _delete_file_from_cache!(db::SQLite.DB, file_rel::String)
    DBInterface.execute(db, "DELETE FROM code    WHERE file = ?", [file_rel])
    DBInterface.execute(db, "DELETE FROM symbols WHERE file = ?", [file_rel])
    DBInterface.execute(db, "DELETE FROM files   WHERE path  = ?", [file_rel])
end

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

"""
    _current_commit_hash(root_path) -> Union{String, Missing}

Return the current HEAD commit hash via `git rev-parse HEAD`, or `missing` if
the directory is not a git repository or git is unavailable.
"""
function _current_commit_hash(root_path::String)::Union{String,Missing}
    try
        result = readchomp(Cmd(`git rev-parse HEAD`; dir=root_path))
        return result
    catch
        return missing
    end
end
