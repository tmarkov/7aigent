Editor environment with query-based pipeline views.

All views are procedural — they re-execute queries on every screen refresh, ensuring views always show current file content even as files change.

{{commands}}

### Matchers

Matchers select initial windows from files. Specified after `in` in `view` and `read-only-peek`.

**Pattern** (view and read-only-peek): `/regex/ in <glob>`

  Match every line in files matched by the glob where the regex is found.
  Each matching line becomes a single-line window, then expanded by operations.
  Use `**` for recursive glob matching (e.g. `**/*.py`).

**Line** (read-only-peek only): `line N in <file-or-glob>` or `line N-M in <file-or-glob>`

  Select a specific line or inclusive line range. Accepts exact file paths
  and glob patterns (e.g. `line 1-50 in **/*.md`).

### Operations

Operations form a left-to-right pipeline applied after the matcher. Separate with `|`.

Expand operations grow each window:

  `context N`           — add N lines above and below
  `up N`                — add N lines above
  `down N`              — add N lines below
  `while-indent`        — extend down while lines are indented (captures blocks)
  `until /pattern/`     — extend down until a line matches (alias: `down-until /pattern/`)
  `up-until /pattern/`  — extend up until a line matches
  `until-blank`         — extend down until a blank line

Filter operations remove windows:

  `filter /pattern/`    — keep only windows where a line matches
  `exclude /pattern/`   — drop windows where a line matches
  `limit N`             — keep only the first N windows
