<!--
The ACTIVE task. A bare `./run-agent.sh` uploads this file and build-image.sh
bakes it in as the image's fallback; the MicroVM renders it into the job
workspace as CLAUDE.md, which is what Claude Code reads as project context.
Swap the job by copying another file from prompts/ over this one — no rebuild.
This copy is prompts/xls-analysis.md, and it needs the spreadsheet libraries in
agent/requirements.txt; that part does need a rebuild, this file does not.

Substituted names, written in double braces (table in README.md): INPUT_DIR,
OUTPUT_DIR, INPUT_COUNT, INPUT_LIST, RUN_ID, LANGUAGE, plus any KEY passed as
--var KEY=VALUE. Listed bare because spelled out they would be substituted into
this comment. Everything in {{INPUT_DIR}}/ is the input, everything left in
{{OUTPUT_DIR}}/ comes back, nothing else leaves the VM. The agent reads this
comment too, so keep it short.
-->

# Spreadsheet analysis job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Analyse every spreadsheet in `{{INPUT_DIR}}/` and leave **two kinds of
artifact**:

1. **`{{OUTPUT_DIR}}/ANALYSIS.md`** — the report, written in **{{LANGUAGE}}**.
2. **`{{OUTPUT_DIR}}/csv/<file>-<sheet>.csv`** — one flat CSV per sheet, so the
   data is usable by something other than a human. Lower-case the names and
   replace spaces with hyphens: `ventas-2024.xlsx` sheet `Ventas` becomes
   `csv/ventas-2024-ventas.csv`.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

## Reading spreadsheets

Three tools are installed, and they are not interchangeable:

```bash
# .xlsx / .xlsm — flat dump of every sheet, one CSV each (the fast path)
xlsx2csv -a "{{INPUT_DIR}}/example.xlsx" extracted/example/

# .xlsx / .xlsm — structure: sheet names, dimensions, cell types, formulas
python3 -c "
import openpyxl
wb = openpyxl.load_workbook('{{INPUT_DIR}}/example.xlsx', data_only=True)
for ws in wb.worksheets:
    print(ws.title, ws.max_row, ws.max_column)
"

# .xls — the LEGACY binary format. openpyxl cannot read it; xlrd only reads it.
python3 -c "
import xlrd
bk = xlrd.open_workbook('{{INPUT_DIR}}/legacy.xls')
for sh in bk.sheets():
    print(sh.name, sh.nrows, sh.ncols)
"
```

Work **one file at a time**. Put intermediate dumps and any scripts you write
in `extracted/` in the workspace root — create it, and keep it out of
`{{OUTPUT_DIR}}/`, which is for finished artifacts only.

**Compute every figure with `python3`, never by reading rows yourself.** Totals,
averages, counts, group-bys, min/max: write a short script, run it, and use its
output. A number you eyeballed from a CSV dump is a number you have invented.

If a file cannot be opened at all, say so plainly in the report for that file
and move on. Do **not** infer its contents from the filename.

## Rules that matter

- **Never invent a value.** Every figure in `ANALYSIS.md` must be traceable to a
  sheet and a column, and must have come out of a script you ran.
- **Report data-quality problems, do not quietly fix them.** Blank cells,
  duplicate rows, negative amounts where none make sense, two spellings of the
  same category, numbers stored as text, dates that did not parse: these are
  findings, not noise. Name the sheet and the row or cell.
- **Cover every file and every sheet.** All {{INPUT_COUNT}} get a section,
  including any that failed to open, and every sheet gets a CSV unless it is
  empty.
- Be specific over generic: concrete figures, column names and row counts beat
  "the file contains sales data".

## Required shape of `ANALYSIS.md`

1. **`# Análisis de hojas de cálculo`** (or the equivalent heading in
   {{LANGUAGE}}) — a short paragraph: how many files and sheets, what the data
   collectively describes, and the single most important finding.

2. **Inventory table** — one row per sheet:

   | Archivo | Hoja | Filas | Columnas | Estado |
   |---|---|---|---|---|
   | ventas-2024.xlsx | Ventas | 48 | 5 | Procesada |
   | ventas-2024.xlsx | Notas | 0 | 0 | Vacía (sin CSV) |

3. **One `##` section per file.** For each sheet: its columns with the type you
   inferred, its row count, and the aggregates that actually say something about
   it — totals, breakdowns by the obvious grouping column, extremes, date range.

4. **`## Calidad de los datos`** — every problem found, grouped by kind, each
   with the sheet and the row/cell it is in, and what it would break downstream.
   If a sheet is clean, say so explicitly rather than omitting it.

5. **`## Síntesis transversal`** — the part a per-file read cannot give you:
   - columns or keys that appear in more than one file, and whether their values
     agree
   - where the files **contradict** each other
   - gaps: what this set does not cover
   - if the files are sequential (periods, versions), how the picture evolves

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming each CSV has
a header row and the row count claimed for it in the inventory table.
