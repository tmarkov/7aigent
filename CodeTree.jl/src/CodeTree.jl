module CodeTree

# ---------------------------------------------------------------------------
# SQL schema
# ---------------------------------------------------------------------------

const CREATE_CODE_TABLE = """
CREATE TABLE IF NOT EXISTS code (
  -- tree structure
  id            TEXT    PRIMARY KEY,
  parent        TEXT,
  depth         INTEGER NOT NULL,
  sibling_order INTEGER DEFAULT 0,

  -- identity
  kind          TEXT    NOT NULL,
  name          TEXT    NOT NULL,
  qname         TEXT,
  language      TEXT,

  -- content
  summary       TEXT,
  source        TEXT,
  signature     TEXT,

  -- location
  file          TEXT,
  line_start    INTEGER,
  line_end      INTEGER,

  -- metrics
  n_lines       INTEGER,
  n_children    INTEGER
);

CREATE INDEX IF NOT EXISTS idx_code_parent ON code(parent);
CREATE INDEX IF NOT EXISTS idx_code_kind   ON code(kind);
CREATE INDEX IF NOT EXISTS idx_code_file   ON code(file);
CREATE INDEX IF NOT EXISTS idx_code_qname  ON code(qname);
"""

const CREATE_REFS_TABLE = """
CREATE TABLE IF NOT EXISTS refs (
  from_id  TEXT NOT NULL,
  to_name  TEXT NOT NULL,
  to_id    TEXT,
  line     INTEGER,
  ref_kind TEXT
);

CREATE INDEX IF NOT EXISTS idx_refs_to   ON refs(to_name);
CREATE INDEX IF NOT EXISTS idx_refs_from ON refs(from_id);
"""

# ---------------------------------------------------------------------------
# TODO: implement
#   load_codebase(path) -> DB handle
#   query helpers, incremental re-index, ref resolution, …
# ---------------------------------------------------------------------------

end # module CodeTree
