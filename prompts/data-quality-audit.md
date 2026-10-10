<!--
Task library entry: column-level data-quality audit. Two ways to use it —

  ./run-agent.sh --prompt prompts/data-quality-audit.md   # this run only
  cp prompts/data-quality-audit.md agent-prompt.md        # make it the default

Needs no rebuild and no `--var`: polars is the default engine and the agent
installs it with uv inside the VM, with the standard library (`csv`, `json`,
`gzip`, `statistics`, `unicodedata`) as the always-available fallback. It needs
nothing beyond the execution role `create-roles.sh` builds either — it reads
INPUT_DIR, writes OUTPUT_DIR and makes no AWS call of its own.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. This one produces a report, one profile CSV per input file and a
ranked issues.csv. It is neither of its neighbours here: `xls-analysis.md`
converts spreadsheets to CSV and writes about what the data *means*, and
`csv-to-sqlite.md` loads CSVs into a queryable database. This entry profiles
**columns** and ships a machine-readable profile plus a severity-ranked issue
list, claiming nothing about what the business data means: "`pedido_id` repeats
in 14 rows" is its output, "sales fell in Q3" never is.
-->

# Data-quality audit job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Profile every tabular file in `{{INPUT_DIR}}/` and leave **three artifacts**:

1. **`{{OUTPUT_DIR}}/AUDIT.md`** — the report, written in **{{LANGUAGE}}**.
2. **`{{OUTPUT_DIR}}/profile/<slug>.csv`** — one row per **column**.
3. **`{{OUTPUT_DIR}}/issues.csv`** — every finding worst first, its header
   exactly `severity,file,column,issue_type,count,pct,example_rows,description`.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

Tabular means `.csv`, `.tsv`, `.jsonl`, `.ndjson` and their `.gz` variants,
gzip decided by the magic bytes `\x1f\x8b` and not by the suffix, which lies.
Anything else is a skip and not an error: list it as not profiled.

The profile slug is the filename lower-cased with spaces and dots hyphenated
(`Ventas 2024.csv` → `profile/ventas-2024-csv.csv`); keep the extension in it,
or `ventas.csv` and `ventas.tsv` overwrite each other. Its columns are these,
in this order in every file, so a `diff` between two runs of the same pipeline
means something (one header line, split here only to fit):

```csv
column,position,inferred_type,type_evidence,rows,non_null,null_pct,
blank_count,distinct,cardinality_ratio,min,max,mean,median,stddev,
shortest,longest,top5,candidate_key,sampled,sample_rows
```

`blank_count` counts `""` and is deliberately separate from `null_pct`, because
`""` and `NULL` mean different things to every loader and collapsing them hides
which one you have. The statistics are numeric-only except `min`/`max`, which
also serve dates; a field that does not apply stays **empty**, never a zero.

## Reading the files

**No third-party Python library is installed here.** `python3` is the bare
standard library and you are not root, so install what you want with `uv`.
**polars** is the default engine:

```bash
mkdir -p work "{{OUTPUT_DIR}}/profile"   # work/ is scratch, in the WORKSPACE
uv run --with polars python -I work/profile.py \
    "{{INPUT_DIR}}/ventas-2024.csv" \
    "{{OUTPUT_DIR}}/profile/ventas-2024-csv.csv"
```

Scripts live in `work/` and run under **`-I`**, because the files in
`{{INPUT_DIR}}/` came from outside this VM and an isolated interpreter will not
import a planted `csv.py` from the working directory. Use polars at volume —
one Rust pass, exact null, distinct and quantile figures, no loop to write —
and the standard library on small files and on anything *malformed*, where
`csv.reader` hands you the raw row and `reader.line_num`: that is how a ragged
row becomes a counted finding instead of a silent coercion. There is **no C
toolchain**, so a library that must compile fails to install; report a failed
install and fall back rather than substituting a figure you did not compute.
Never `uv pip install --system`: it needs root.

Read with `pl.read_csv(path, separator=sep, infer_schema=False,
missing_utf8_is_empty_string=True)`. The first keeps every column a string,
because typing it is *your* job over every value and an inferring reader has
already nulled the one bad value that is the finding; the second keeps `""`
distinct from an absent field. **Never** pass `truncate_ragged_lines=True` to
make a read succeed — it discards the very fields you were asked to report.

## The checks, and what makes each one a finding

- **Type inferred over every value, not a sample.** The one value in 50 000
  that forces a column to TEXT *is* the finding, with its row number: that row
  is what breaks the load. `type_evidence` records how you decided.
- **Numbers stored as text** — thousands separators, currency symbols,
  parentheses for negatives, trailing spaces: report the pattern and the count.
  The comma is ambiguous: `1,234` matching `\d{1,3}(,\d{3})+` throughout is a
  thousands separator, one comma with one or two digits is a decimal comma, and
  both in one column is **ambiguous** — flag it, never pick, because picking
  wrong moves a decimal three places.
- **Mixed and ambiguous dates**: `2026-03-04` beside `04/03/2026` is a finding
  by itself. Scan the whole column — a first component above 12 proves
  day-first, a second above 12 month-first, both means mixed, and **neither
  means ambiguous**: say so rather than choosing, which shifts dates by months.
- **Text that will not compare equal**, which is what splits a group-by:
  whitespace at either end; non-breaking and zero-width characters, reported as
  codepoints, because `U+00A0` is actionable and "a strange space" is not; and
  labels collapsing under `casefold()` + `strip()` + accent folding, reported
  as the whole group with per-spelling counts — `Madrid`, `madrid`, ` MADRID`
  is why one city shows up three times in a total.
- **Encoding damage.** Decode `utf-8-sig` first so a BOM does not join the
  first column's name, then `utf-8`, then `latin-1`, which never raises:
  reaching it means utf-8 failed, and the inventory names that fallback rather
  than taking it silently. Report mojibake (`Ã©`, `â€™`) beside that encoding.
- **Duplicates, keys and the joins resting on them**: fully duplicated rows
  (hash the row), repeated values in a column that looked unique, and a
  **candidate key** flag wherever `distinct == non_null == rows`. Test the
  obvious composite pairs (top cardinality, plus id/code/date names) and name
  which you tested; an untested pair must not read as "not a key". Across
  files, report columns shared by name or by value overlap with the **orphan
  rate each way**, over rows and not distinct values: "12,4 % of rows in
  `ventas.csv` carry a `cliente_id` in no row of `clientes.csv`" is the most
  expensive line in the report — a join quietly dropping an eighth of them.
- **Columns that say nothing or lie about their name**: constants, all-nulls,
  and `is_active` holding `0`, `1`, `yes`, `Y` and empty — four encodings of one
  boolean, and every consumer picks a different one.
- **Rows and values worth a human's attention**: outliers 1,5 × IQR beyond the
  quartiles (`statistics.quantiles`); sentinels posing as data (`-1`, `9999`,
  `0000-00-00`, `1970-01-01`, `N/A`, `NULL`); negatives where none belong;
  ragged rows whose field count differs from the header's; JSONL records whose
  key set differs from the rest, an absent key kept apart from one present as
  `null`. All with counts and first row numbers, and worth attention rather
  than errors: only the operator knows whether `-1` is a refund.

**Severity, and how `issues.csv` ranks (by severity, then by `count`):**

| Severity | Means | Example |
|---|---|---|
| `critical` | the file cannot be loaded, or a key is not a key | ragged rows, duplicated key, failed decode |
| `high` | a figure computed from it would be wrong | numbers as text, sentinels in a numeric column |
| `medium` | a join or group-by would be wrong | near-duplicate labels, whitespace in keys, orphans |
| `low` | cosmetic | trailing spaces in free text, a constant column |

`severity` and `issue_type` are stable lower-case tokens (`critical`,
`duplicate_key`, `numeric_as_text`, …) whatever {{LANGUAGE}} is, with the human
sentence in `description`: the report is translated, the machine-readable file
has to sort and grep the same across runs. Its numbers use `.` as the decimal
separator and `AUDIT.md` formats the **same values** for a {{LANGUAGE}} reader
(`1,1 %`) — format differently, never recompute.

Read **every row** by default. Sample only if a full pass will not finish
inside the run; then take the first N rows, state N and the rule in
`## Muestreo`, fill `sampled`/`sample_rows`, and label every rate in that
file's section as from a sample. A null rate presented as exact when it came
from the first 10 000 rows is the failure this task exists to prevent — and so
is reading a sampled distinct count as a count, since it is a **lower bound**.

## Rules that matter

- **Never fix anything** — no imputed values, no deduplicated copy, no
  normalised categories, no trimmed keys, no cleaned file: the deliverable is
  the finding. A cleaned dataset that leaves this VM without the operator
  agreeing to the rules is one nobody can reconcile against the source.
- **Never invent a figure.** Every number in `AUDIT.md` and every row of
  `issues.csv` came out of a script you ran, each issue cites the file, the
  column and the rows (all of them, or a labelled sample), and the profile CSVs
  and the report never show two numbers for one thing.
- **Quote column names verbatim.** `fecha_envío` stays `fecha_envío` whatever
  language the prose is in; a translated column name cannot be grepped for.
- **Cover all {{INPUT_COUNT}} inputs**, the skipped and the unparseable
  included. A wrong-type file is a skip, not an error.
- **`{{OUTPUT_DIR}}/` is uploaded verbatim**, so it holds only `AUDIT.md`,
  `profile/` and `issues.csv`: dumps and scripts stay in `work/`, where a
  forgotten directory cannot ship as if it were the deliverable.
- Install failures, files you could not read and doubts go in the report. And
  `claude` is retried up to three times in this same workspace, so rebuild the
  profiles wholesale each attempt and never append to them.

## Required shape of `AUDIT.md`

1. **`# Auditoría de calidad de datos`** (or the equivalent heading in
   {{LANGUAGE}}) — files, rows, columns, issues per severity, **the one thing
   to fix first**.

2. **Inventory table**, one row per input file:

   | Archivo | Codificación | Filas | Columnas | Nulos | Problemas |
   |---|---|---|---|---|---|
   | ventas-2024.csv | utf-8-sig | 1 248 | 9 | 0,8 % nulos | 3 altas |

3. **One `##` section per file** — its columns (`| # | Columna | Tipo
   inferido | Nulos | Vacíos | Distintos |`) and its findings, with row numbers.

4. **`## Problemas por severidad`** — every finding ranked, the same rows as
   `issues.csv`:

   | Severidad | Archivo | Columna | Tipo | Nº | % | Filas | Descripción |
   |---|---|---|---|---|---|---|---|
   | Crítica | ventas-2024.csv | pedido_id | Clave duplicada | 14 | 1,1 % | 88, 141, 207 | 14 pedidos aparecen dos veces |
   | Media | clientes.csv | ciudad | Etiquetas duplicadas | 61 | 1,4 % | 7, 19 | Madrid / madrid / MADRID |

5. **`## Relaciones entre archivos`** — shared columns, value overlap and the
   orphan rate each way, with the join each one would break.

6. **`## Muestreo`** — what was sampled, the rule, the size and why; if nothing
   was, say so, because a missing section reads as an omission.

7. **`## Herramientas utilizadas`** — one line per tool with the version you
   actually ran (`uv --version`, `python3 --version`, `polars.__version__`),
   what each was for, and any install that failed: it is how the next run of
   this task knows what it took.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the counts:
{{INPUT_COUNT}} file(s) → N profiled + N skipped, one profile CSV each with one
row per column, and `issues.csv` as long as `## Problemas por severidad`.
