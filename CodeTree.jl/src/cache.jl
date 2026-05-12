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
const _CACHE_CODEBASE_NAME_KEY = "codebase_name"
const _CACHE_COMPAT_VERSION = "4"

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
    codebase_name = basename(root_path)
    _ensure_cache_compatible!(db, codebase_name)
    _init_cache_schema!(db)
    _set_cache_meta!(db, _CACHE_COMPAT_KEY, _CACHE_COMPAT_VERSION)
    _set_cache_meta!(db, _CACHE_CODEBASE_NAME_KEY, codebase_name)
    return db
end

function _init_cache_schema!(db::SQLite.DB)::Nothing
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
    return nothing
end

function _ensure_cache_compatible!(db::SQLite.DB, codebase_name::String)::Nothing
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS cache_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)
    cached_version = _get_cache_meta(db, _CACHE_COMPAT_KEY)
    cached_codebase_name = _get_cache_meta(db, _CACHE_CODEBASE_NAME_KEY)
    if cached_version == _CACHE_COMPAT_VERSION &&
       cached_codebase_name == codebase_name
        return
    end

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
    return nothing
end

function _first_result_row(result)::Union{Nothing,Any}
    rows = collect(Tables.namedtupleiterator(result))
    isempty(rows) && return nothing
    return rows[1]
end

function _sql_text_or_nothing(value)::Union{String,Nothing}
    (isnothing(value) || ismissing(value)) && return nothing
    return String(value)
end

function _sql_text_or_missing(value)::Union{String,Missing}
    text = _sql_text_or_nothing(value)
    isnothing(text) && return missing
    return text
end

function _sql_int_or_missing(value)::Union{Int,Missing}
    (isnothing(value) || ismissing(value)) && return missing
    return Int(value)
end

_sql_nullable(value) = ismissing(value) ? nothing : value

function _get_cache_meta(db::SQLite.DB, key::String)::Union{String,Nothing}
    row = _first_result_row(DBInterface.execute(
        db, "SELECT value FROM cache_meta WHERE key = ?", [key],
    ))
    isnothing(row) && return nothing
    return _sql_text_or_nothing(Tables.getcolumn(row, :value))
end

function _set_cache_meta!(db::SQLite.DB, key::String, value::String)::Nothing
    DBInterface.execute(
        db,
        "INSERT OR REPLACE INTO cache_meta (key, value) VALUES (?, ?)",
        [key, value],
    )
    return nothing
end

# ---------------------------------------------------------------------------
# Read helpers
# ---------------------------------------------------------------------------

"""
    _get_cached_hash(db, path) -> String or nothing

Return the stored SHA-256 hash for `path`, or `nothing` if not cached.
"""
function _get_cached_hash(db::SQLite.DB, path::String)::Union{String,Nothing}
    row = _first_result_row(DBInterface.execute(
        db, "SELECT hash FROM files WHERE path = ?", [path],
    ))
    isnothing(row) && return nothing
    return _sql_text_or_nothing(Tables.getcolumn(row, :hash))
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
)::Union{Tuple{Vector{CodeRow}, Vector{SymbolRow}}, Nothing}

    code_result = DBInterface.execute(db, """
        SELECT id, parent, depth, sibling_order, kind, name, qname, language,
               summary, source, signature, line_start, line_end, n_lines, n_children
        FROM code WHERE file = ?
        ORDER BY depth ASC, sibling_order ASC
    """, [file_rel])

    code_rows = CodeRow[]
    for r in code_result
        push!(code_rows, CodeRow(
            String(Tables.getcolumn(r, :id)),
            _sql_text_or_missing(Tables.getcolumn(r, :parent)),
            Int(Tables.getcolumn(r, :depth)),
            Int(Tables.getcolumn(r, :sibling_order)),
            String(Tables.getcolumn(r, :kind)),
            String(Tables.getcolumn(r, :name)),
            _sql_text_or_missing(Tables.getcolumn(r, :qname)),
            _sql_text_or_missing(Tables.getcolumn(r, :language)),
            _sql_text_or_missing(Tables.getcolumn(r, :summary)),
            _sql_text_or_missing(Tables.getcolumn(r, :source)),
            _sql_text_or_missing(Tables.getcolumn(r, :signature)),
            file_rel,
            _sql_int_or_missing(Tables.getcolumn(r, :line_start)),
            _sql_int_or_missing(Tables.getcolumn(r, :line_end)),
            _sql_int_or_missing(Tables.getcolumn(r, :n_lines)),
            Int(Tables.getcolumn(r, :n_children)),
        ))
    end
    isempty(code_rows) && return nothing

    # Symbols are currently re-extracted globally by extract_symbols! after
    # loading, so sym_rows from cache are not used by the caller.  They are
    # kept here so the cache round-trips correctly and so a future optimization
    # (skipping global re-extraction for cached files) is straightforward.
    sym_result = DBInterface.execute(db,
        "SELECT node_id, symbol, kind FROM symbols WHERE file = ?", [file_rel])
    sym_rows = SymbolRow[]
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
)::Nothing
    ch = _sql_nullable(commit_hash)
    DBInterface.execute(db,
        "INSERT OR REPLACE INTO files (path, hash, commit_hash) VALUES (?, ?, ?)",
        [path, hash, ch])
    return nothing
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
    sym_rows::Vector{SymbolRow},
)::Nothing
    DBInterface.execute(db, "BEGIN")
    try
        _delete_cached_file_rows!(db, file_rel)
        _upsert_file!(db, file_rel, hash, commit_hash)

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
                _sql_nullable(r.parent),
                r.depth,
                r.sibling_order,
                r.kind,
                r.name,
                _sql_nullable(r.qname),
                _sql_nullable(r.language),
                _sql_nullable(r.summary),
                _sql_nullable(r.source),
                _sql_nullable(r.signature),
                _sql_nullable(r.line_start),
                _sql_nullable(r.line_end),
                _sql_nullable(r.n_lines),
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
    return nothing
end

function _delete_cached_file_rows!(db::SQLite.DB, file_rel::String)::Nothing
    DBInterface.execute(db, "DELETE FROM code    WHERE file = ?", [file_rel])
    DBInterface.execute(db, "DELETE FROM symbols WHERE file = ?", [file_rel])
    return nothing
end

"""
    _delete_file_from_cache!(db, file_rel)

Remove all cache entries for `file_rel`.
"""
function _delete_file_from_cache!(db::SQLite.DB, file_rel::String)::Nothing
    _delete_cached_file_rows!(db, file_rel)
    DBInterface.execute(db, "DELETE FROM files   WHERE path  = ?", [file_rel])
    return nothing
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
