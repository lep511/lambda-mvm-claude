<!--
Task library entry: spreadsheet analysis. Two ways to use it —

  ./run-agent.sh --prompt prompts/xls-analysis.md    # this run only
  cp prompts/xls-analysis.md agent-prompt.md         # make it the default

Needs no rebuild and nothing added to the image: the spreadsheet libraries it
uses (xlsx2csv, openpyxl, xlrd) are named below and the agent installs them
itself with uv, inside the VM. A task needing pandas is one more word here.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. This one deliberately produces several, in a subdirectory.
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

**No Python libraries are installed in this VM.** `python3` is the bare standard
library, you are not root, and there is nothing to read `.xlsx` with until you
install it — so the choice of tools is yours to make and yours to set up, with
`uv`, which is installed for exactly this. These three are the ones that work on
spreadsheets, and they are not interchangeable:

```bash
# .xlsx / .xlsm — flat dump of every sheet, one CSV each (the fast path)
uvx xlsx2csv -a "{{INPUT_DIR}}/example.xlsx" extracted/example/

# .xlsx / .xlsm — structure: sheet names, dimensions, cell types, formulas
uv run --with openpyxl python -c "
import openpyxl
wb = openpyxl.load_workbook('{{INPUT_DIR}}/example.xlsx', data_only=True)
for ws in wb.worksheets:
    print(ws.title, ws.max_row, ws.max_column)
"

# .xls — the LEGACY binary format. openpyxl cannot read it; xlrd only reads it.
uv run --with 'xlrd>=2.0' python -c "
import xlrd
bk = xlrd.open_workbook('{{INPUT_DIR}}/legacy.xls')
for sh in bk.sheets():
    print(sh.name, sh.nrows, sh.ncols)
"
```

`uvx` runs a command-line tool, `uv run --with` runs a script against libraries
it installs on the fly; both cache, so the second call is fast. If you would
rather have one environment for the whole job, build it once in the workspace —
`uv venv .venv && uv pip install openpyxl 'xlrd>=2.0' xlsx2csv` — and use
`.venv/bin/python` from then on. Add whatever else you judge useful; `pandas` is
one `--with pandas` away. Two hard rules: **never** `uv pip install --system`
(it needs root, and fails), and if an install fails, say so in the report rather
than working around it with figures you did not compute.

Work **one file at a time**. Put intermediate dumps and any scripts you write
in `extracted/` in the workspace root — create it, and keep it out of
`{{OUTPUT_DIR}}/`, which is for finished artifacts only.

**Compute every figure with a script, never by reading rows yourself.** Totals,
averages, counts, group-bys, min/max: write a short script, run it, and use its
output. A number you eyeballed from a CSV dump is a number you have invented.
The standard library (`csv`, `statistics`) is plenty for the arithmetic, so
plain `python3` will do unless you decide otherwise.

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

6. **`## Herramientas utilizadas`** — one line naming the libraries and tools
   you installed and what each was for, plus any install that failed. It is how
   the next run of this task knows what it actually took.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming each CSV has
a header row and the row count claimed for it in the inventory table.
