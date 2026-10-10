<!--
Task library entry: every delimited file in the input loaded into one
queryable SQLite database. Two ways to use it —

  ./run-agent.sh --prompt prompts/csv-to-sqlite.md    # this run only
  cp prompts/csv-to-sqlite.md agent-prompt.md         # make it the default

Needs no rebuild and, unusually for this library, the agent installs nothing
with uv: `sqlite3`, `csv` and `gzip` are standard library, so the job is plain
`python3`. Worth saying out loud, because the confusion here runs the other
way — the `sqlite3` *command-line tool* is NOT in the image, only the module.
Needs nothing beyond the execution role create-roles.sh builds: it reads
INPUT_DIR, writes OUTPUT_DIR and makes no AWS call of its own.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. Different here is the *binary* deliverable, which fails in ways
markdown cannot — WAL sidecars ship a main file missing rows, and the 64 MB
ceiling drops it silently. Nearest neighbour prompts/xls-analysis.md faces the
other way: it opens spreadsheets, flattens them to CSV and analyses the
numbers, where this one takes already-flat text and builds a machine artifact,
so its report describes the schema and not the business.
-->

# CSV to SQLite job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Load every delimited file in `{{INPUT_DIR}}/` into **one** SQLite database, one
table per input file, and leave **three artifacts**:

1. **`{{OUTPUT_DIR}}/data.sqlite`** — the database. One file and only one: no
   `-wal`, no `-shm`, no `-journal` beside it.
2. **`{{OUTPUT_DIR}}/SCHEMA.md`** — the report, written in **{{LANGUAGE}}**.
3. **`{{OUTPUT_DIR}}/queries/NN-<name>.sql`** with a matching `NN-<name>.csv` —
   queries the data actually supports, each beside the result it returned, so
   the database arrives with proof that it is queryable.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

In scope: `.csv`, `.tsv`, `.csv.gz`/`.tsv.gz`, and a `.txt` that parses as
delimited. Anything else — a PDF, an `.xlsx`, prose in a `.txt` — is not an
error and not your job: skip it and list it as skipped.

## The engine is here; the command-line tool is not

```bash
command -v sqlite3 || true   # expect NOTHING: the CLI is not in this image
python3 -c 'import sqlite3; print(sqlite3.sqlite_version)'; python3 --version
```

Check that before reaching for it: `.import`, `.mode csv` and `.headers on`
belong to the **command-line** tool, an apt package, and you are not root. The
**module** is standard library, so nothing needs installing and the way in is a
Python script. Report `sqlite3.sqlite_version`, the engine compiled into this
Python, not the deprecated `sqlite3.version`, which is the module's own number
and a meaningless figure in a report. `uv` is here if you want a library anyway
(`uv run --with chardet python3 x.py`) — you do not need one, name anything you
install, and never `uv pip install --system`, which needs root.

## Build it in the workspace, deliver it at the end

`{{OUTPUT_DIR}}/` is uploaded verbatim however the job ends, so a half-written
database there is indistinguishable from a finished one. Build in `build/`
(`mkdir -p build`, which also holds every script you write) and copy in once at
the end; scratch left in `{{OUTPUT_DIR}}/` ships as if it were the deliverable.
WAL fails the same way — `journal_mode=WAL` leaves committed rows in
`data.sqlite-wal` until a checkpoint, so three files ship, the main one
incomplete, and a reader sees missing rows without knowing it.

```python
conn = sqlite3.connect("build/data.sqlite")
conn.execute("PRAGMA journal_mode=DELETE")  # explicit: no -wal/-shm sidecar
# ... import every file ...
conn.commit()
conn.execute("VACUUM")   # after commit: VACUUM cannot run in a transaction
conn.close()             # releases the journal; an open handle leaves one
```

```bash
cp build/data.sqlite "{{OUTPUT_DIR}}/data.sqlite"
ls -l "{{OUTPUT_DIR}}" "{{OUTPUT_DIR}}/queries"  # one .sqlite, no -wal/-shm
wc -c < "{{OUTPUT_DIR}}/data.sqlite"             # ceiling is 67108864 bytes
```

That `ls` is the proof, not a formality, and once copied you query
`build/data.sqlite`, never the copy. **Above 67108864 bytes the runtime skips
the artifact and records it as skipped** — a run that looks successful and
delivers no database — so if `wc -c` says so, report it and ship `SCHEMA.md`
and `queries/` anyway. `_status.json` is reserved in `{{OUTPUT_DIR}}/` for the
runtime's completion signal; yours would be skipped.

## A retry must not double your rows

`claude -p` is retried up to **3 times in this same workspace** and a retry
re-reads this prompt from the top; a second import into an existing database
appends every row again, and nothing downstream can tell 2 496 rows from 1 248
imported twice. Make the result a function of the input and not of how many
attempts it took: `os.remove("build/data.sqlite")` if it exists (or
`DROP TABLE IF EXISTS` every table) before importing, and
`rm -f "{{OUTPUT_DIR}}"/queries/*` too, or a result file from an attempt that
no longer produces it ships as if it were current.

## Reading a delimited file: sniff, do not assume

Run every script that reads `{{INPUT_DIR}}/` as **`python3 -I build/load.py`**:
those files came from outside this VM, and an isolated interpreter cannot
import a planted `csv.py` from the working directory as `import csv`. A comma
is a guess — a Spanish Excel writes `;` — so ask the standard library, and
record a dialect you had to assume as assumed rather than detected:

```python
sample = fh.read(64 * 1024); fh.seek(0)
dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")  # bound the guess
has_header = csv.Sniffer().has_header(sample)
rows = csv.reader(fh, dialect)        # the whole dialect: it carries quoting
```

Bound `delimiters=` or `Sniffer` picks whatever character happens to be regular
and hands you one column named after half the header; pass the dialect object
itself to `csv.reader`, since the quote character came with it. Both calls
raise `csv.Error` on a single-column or tiny file: catch it and fall back to
`,` with the first row as header. Encoding is the same guess — `utf-8-sig`
first, or a BOM becomes part of the first column's name and every query against
that column misses; `latin-1` as the fallback, recorded in the report as
`latin-1 (fallback)`, because it decodes any byte sequence, therefore never
fails, therefore proves nothing, and mojibake is a finding. Use
`gzip.open(path, "rt", encoding=enc, newline="")` for `.gz`, and `newline=""`
on every text handle or a quoted line break splits one row into two.

**Ragged rows** are never dropped in silence: pad a short row with `None` so
the missing fields land NULL, keep the first `len(header)` fields of a long
one, count both, and report the count with the first few `reader.line_num`
values — the physical line a human can go and look at, rather than an index
into the rows you parsed.

## Columns: names first, then types

Derive the table from the filename stem and the columns from the header, and
**quote every identifier**: `'CREATE TABLE "%s" ("%s" %s, ...)'`. A column
called `order`, `group`, `Importe (€)` or `2024` is a syntax error in
hand-built DDL, raised one file into the import with nothing saying which name
caused it. Values still go in as `?` parameters, never formatted into the SQL,
because one apostrophe in a field would end the statement.

Sanitise before quoting: strip accents with
`unicodedata.normalize("NFKD", s).encode("ascii", "ignore")` so `Año` becomes
`ano` and not `a_o`, lower-case, map runs of non-alphanumerics to `_`, trim
them from the ends, prefix a digit-leading name (`2024` → `c_2024`), and prefix
a table name starting `sqlite_`, which is **reserved** and refused outright.
Sanitising collapses `Total €` and `Total $` onto one `total_`, so deduplicate
with a suffix rather than let one column overwrite the other, and keep the
header row verbatim in `_manifest` so the mapping is recoverable from the
database alone.

Then decide INTEGER / REAL / TEXT by scanning **every value in the column**,
not the first ten rows: a column integral for 49 999 rows that holds `N/D` in
one is a TEXT column, and sampling is how you declare it INTEGER and lose that
row.

```python
def classify(v):                      # "" is NULL, not evidence of a type
    if v == "": return None
    try: int(v); return "INTEGER"
    except ValueError: pass
    try: float(v); return "REAL"
    except ValueError: return "TEXT"
# a column's type is the widest classify() returned: INTEGER < REAL < TEXT
```

`int("1_000")`, `float("inf")` and `float("nan")` all succeed in Python and no
spreadsheet meant to write any of them, so reject underscores and non-finite
results instead of letting them widen a column to REAL. **The value that forced
a column to TEXT is a finding**, reported with its file, column and row number,
because a column meant to be numeric that silently is not is exactly what a
downstream `SUM()` gets wrong. Money and decimals stay **TEXT** or integer
minor units, never REAL: REAL is a binary float, `0.1 + 0.2` is not `0.3`, and
a total over a few thousand invoice lines drifts by cents. Say which you chose,
per column.

## Self-describing, indexed, and verified

Write one row per imported file into a `_manifest` table **inside** the
database, so the artifact explains itself to whoever opens it without
`SCHEMA.md`: `source_file`, `table_name`, `delimiter`, `encoding`,
`rows_in_file`, `rows_imported`, `column_count`, `original_headers`.
`_manifest` is yours, not an input — no `##` section, no row in the import
table. Index where the data suggests one, meaning a column whose values are
unique over every row and a column named `*_id` or `id_*`; that is a judgement
call and not a rule, since an index on a column with four distinct values costs
space, buys nothing, and dead weight matters under a 64 MB ceiling — so name
each index and its reason, and say if you created none.

Count the data rows you handed to the inserter while reading each file, then
ask the database: `SELECT COUNT(*) FROM "<table>"`. Both numbers go in the
import table side by side, and if they differ you **report the mismatch** —
file, table, both counts, and the ragged rows that explain the gap. Never
reconcile it by re-importing or by printing the number you expected: a count
you adjusted is a count nobody can check.

## The example queries

Four to six, each one the data **actually supports**, written after you know
the schema: rows per table, a `GROUP BY` on a low-cardinality text column,
`MIN`/`MAX` on a date-like column, a join between two tables that share a
key — check that one by counting the overlapping values first, because an
overlap of zero is the finding and the query is not worth shipping. `LIMIT`
anything that could return most of a table. The `.sql` holds the statement
verbatim under a leading `--` line saying what it answers; the `.csv` holds
what it returned, header from `cursor.description`, written with `csv.writer`,
so the result is the engine's and not your transcription of it. An empty result
is reported, not quietly replaced.

## Rules that matter

- **Delete the database before importing.** A retry re-reads this prompt; a
  second import doubles every row.
- **One file leaves as the database.** Commit, `VACUUM`, `close()`, copy, then
  `ls` to check nothing came with it.
- **Never invent anything.** Every delimiter, encoding, type and count came out
  of a script you ran against a file you read — never from eyeballing a dump,
  and never from the filename.
- **A failure is reported, not papered over**: an unreadable file, a failed
  install, a count that will not match. An artifact built from an assumption is
  worse than a missing one, because nothing downstream can tell the difference.
- **Cover all {{INPUT_COUNT}} inputs**, the skipped and the failed included. A
  file of the wrong type is not an error.

## Required shape of `SCHEMA.md`

1. **`# Esquema de la base de datos`** (or the equivalent heading in
   {{LANGUAGE}}) — files found, tables created, total rows, the size of
   `data.sqlite` in bytes, and anything that failed.

2. **Import table** — one row per input file:

   | Archivo | Tabla | Delimitador | Codificación | Filas en el archivo | Filas en la tabla | Estado |
   |---|---|---|---|---|---|---|
   | ventas-2024.csv | ventas_2024 | , | utf-8 | 1 248 | 1 248 | Importado |
   | clientes.tsv | clientes | \t | latin-1 (fallback) | 530 | 528 | 2 filas irregulares |
   | notas.txt | — | — | — | — | — | Omitido (no es texto delimitado) |

3. **One `##` section per table** — its `CREATE TABLE` DDL verbatim in a `sql`
   block, read back from `sqlite_master.sql` so it is what the engine stored
   and not what you meant to write, then one row per column plus the indexes:

   | Columna | Cabecera original | Tipo | Evidencia |
   |---|---|---|---|
   | importe_eur | Importe (€) | TEXT | Decimal: TEXT para no perder céntimos |
   | unidades | Unidades | INTEGER | 1 248 valores, todos enteros |
   | descuento | Descuento | TEXT | Fila 912 contiene `N/D`; el resto, REAL |

4. **`## Consultas`** — per query file: its name, the question it answers, and
   how many rows its `.csv` holds.

5. **`## Calidad de los datos`** — every finding with its file and row number:
   ragged rows, encoding fallbacks, the values that forced a column to TEXT,
   duplicate rows, empty files, count mismatches. If a table is clean, say so.

6. **`## Herramientas utilizadas`** — one line per tool with the version you
   ran: `sqlite3.sqlite_version`, `python3 --version`, and anything installed
   with `uv` and what for. If you installed nothing, say so — here that is the
   expected outcome, and it tells the next run the job needs no network.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the counts
agree: {{INPUT_COUNT}} input file(s) → N tables → each table's
`SELECT COUNT(*)` matching the rows counted while reading its file, and
`data.sqlite` under the ceiling with no `-wal` or `-shm` beside it.
