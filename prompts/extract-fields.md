<!--
Task library entry: schema-constrained field extraction from business documents
— invoices, receipts, purchase orders, delivery notes, simple contracts — into
one strict JSON object per document. Two ways to use it —

  ./run-agent.sh --prompt prompts/extract-fields.md    # this run only
  cp prompts/extract-fields.md agent-prompt.md         # make it the default

Needs no rebuild and no new grant: poppler-utils (`pdftotext`, and `pdftoppm`
for the scanned path) is already in the Dockerfile, and `jsonschema` is a Python
library, so it is named below and the agent installs it itself with uv inside
the VM. Document extraction is where a reader expects an AWS service and a fresh
IAM policy, so: there is no Textract call and no Bedrock call of this task's
own — the agent reading the document *is* the extractor, and the stock execution
role create-roles.sh builds is enough.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. Different here is that the deliverable is machine-readable and
schema-checked — the JSON is the product, validated before the job ends, and the
report is the smaller half.
-->

# Field extraction job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Extract structured fields from every business document in `{{INPUT_DIR}}/` —
invoices, receipts, purchase orders, delivery notes, simple contracts — and
leave **three artifacts**:

1. **`{{OUTPUT_DIR}}/json/<slug>.json`** — one strict object per document,
   matching the schema below exactly. This is the deliverable.
2. **`{{OUTPUT_DIR}}/extracted.csv`** — one flattened row per document, for the
   people who will open it in a spreadsheet. Built from the JSON at the end,
   never appended to as you go; see "extracted.csv".
3. **`{{OUTPUT_DIR}}/EXTRACTION.md`** — the report, in **{{LANGUAGE}}**.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

`.pdf`, `.txt`, `.md` and an image of a document (`.png`, `.jpg`) are in scope.
Anything else — a spreadsheet, an archive, a binary — is not an error and not
your job: skip it and list it in the report with the reason.

**The report is written in {{LANGUAGE}}. The JSON is not.** Its keys are the
fixed English identifiers below; its values are verbatim from the document, in
whatever language that document is written in. A schema whose field names change
with the run's language is a schema nothing can consume — its reader is a
program, written against these names.

## The schema

Every file in `json/` is this object: every key **always present**, every value
**nullable**, no key ever added, renamed or dropped. The `//` comments are for
you — JSON has none, and a file carrying one breaks the first `json.load`
downstream.

```jsonc
{
  "source_file": "Factura 2026-0412.pdf",  // original name, verbatim
  // closed enum: invoice|receipt|purchase_order|delivery_note|contract|unknown
  "document_type": "invoice",
  "document_number": "2026-0412",
  "issue_date": "2026-04-03",   // ISO YYYY-MM-DD; read "Dates" below first
  "due_date": null,             // not in the document -> null, never a guess
  "currency": "EUR",            // ISO 4217, uppercase
  // both parties: name, tax_id, address — any of the three may be null
  "seller": {"name": "Acme Ibérica S.L.", "tax_id": "B12345678",
             "address": "C/ Mayor 3, 28013 Madrid"},
  "buyer":  {"name": "Clienta S.A.", "tax_id": null, "address": null},
  // one object per row, [] when the document has no item table
  "line_items": [{"description": "Soporte técnico, abril 2026",
                  "quantity":   {"raw": "12,00", "value": "12"},
                  "unit_price": {"raw": "85,00 €", "value": "85.00"},
                  "amount":     {"raw": "1.020,00 €", "value": "1020.00"}}],
  "subtotal":   {"raw": "1.020,00 €", "value": "1020.00"},
  "tax_rate":   {"raw": "21 %", "value": "21"},   // percent, not a fraction
  "tax_amount": {"raw": "214,20 €", "value": "214.20"},
  "total":      {"raw": "1.234,20 €", "value": "1234.20"},
  "payment_terms": "30 días fecha factura",
  // read_method: pdftotext-layout | pdftotext-raw | pdfplumber | page-images
  // | plain-text.  arithmetic_check: "OK" or the discrepancy, never a fix.
  // fields_total is always 21: every field above except source_file, this
  // object and evidence — the 11 document and party keys, line_items itself
  // plus its 4 columns, the 4 money totals and payment_terms. A fixed
  // denominator is what makes the ratio comparable across documents.
  "extraction": {"read_method": "pdftotext-layout", "pages": 2,
                 "fields_found": 18, "fields_total": 21,
                 "arithmetic_check": "OK", "notes": "Sin vencimiento."},
  // every populated field -> the verbatim text behind it; dotted paths for
  // nested fields, one entry per line-item row rather than per cell
  "evidence": {"total": "TOTAL FACTURA .......... 1.234,20 €",
               "issue_date": "Fecha de emisión: 03/04/2026",
               "seller.tax_id": "NIF: B12345678"}
}
```

**Money and quantities are a pair of strings, never a JSON number.** `raw` is
the characters the document uses, `value` the `decimal.Decimal`-parsed form —
both, because a normalisation is a claim and the raw text is its proof; strings,
because a JSON number goes through a binary float, which cannot represent 0.10,
and a cent of drift in an invoice total is a reconciliation someone does by
hand. Parse with `Decimal`, never `float`; a parenthesised credit-note amount
keeps its `raw` and gets a negative `value`.

## Reading the document

Work **one document at a time**: read it, write its JSON, open the next.
Extracted text, page images and every script you write go in **`work/`** in the
workspace root — never in `{{OUTPUT_DIR}}/`, which is uploaded verbatim, so a
forgotten `work/` there ships megabytes of PNGs as the deliverable.

```bash
mkdir -p work "{{OUTPUT_DIR}}/json"
pdfinfo "{{INPUT_DIR}}/factura.pdf"      # page count for extraction.pages
pdftotext -layout "{{INPUT_DIR}}/factura.pdf" work/factura.txt
uv run --with pdfplumber python -I work/tables.py   # .extract_table() per page
```

`-layout` first and always: without it a line-item table collapses into soup
where a description and the number beside it no longer share a line, and every
amount becomes a guess about which row it came from. When `-layout` interleaves
the columns of a dense header, re-extract with `-raw` and record
`pdftotext-raw`. When the item table needs real cell boundaries, `pdfplumber`
has them — a library, and this image carries no third-party Python, so install
it with `uv` as above. You are not root, so never `uv pip install --system` (it
fails); there is no C toolchain, so anything needing a compiler will not build.
A failed install goes in the report and falls back to `pdftotext`, never to
numbers you did not read.

A PDF with no text layer (`pdffonts` shows no embedded font, `pdftotext` yields
almost nothing against a double-digit page count) is a scan. There is no OCR
engine here and you need none: **you can read an image.** Rasterise at 150 dpi —
legible for an A4 at ~3k tokens a page, where `pdfimages -j` would give you the
embedded scan at 600 dpi for no extra readability — and read the PNGs one at a
time, writing each page's fields down before rendering the next. Label these
documents `page-images` in `read_method`: a transcription is weaker evidence
than an extraction, and whoever audits a total needs to know which they have.

```bash
pdftoppm -r 150 -png -f 1 -l 4 "{{INPUT_DIR}}/escaneo.pdf" work/escaneo
# -> work/escaneo-01.png, ...   then Read each PNG in turn
```

**Dates.** Normalise to `YYYY-MM-DD` only when the document settles the
convention — a month name, an ISO date elsewhere on the page, a `dd/mm/yyyy`
label, a day past 12. `03/04/2026` with nothing else to go on is **ambiguous**:
keep the original string in `evidence`, say so in `extraction.notes`, leave the
field `null`. A coin flip there is wrong eleven months a year and looks exactly
like a right answer.

## Writing and validating the JSON

**Build and read JSON with Python**, never by pasting strings into a template
and never with `jq`, which is the reflex here and **is not in this image**:
vendor names carry quotes, accents, ampersands and newlines, and one of them
turns a hand-built file into something no consumer can parse. Run every script
that touches `{{INPUT_DIR}}/` with `-I`, because those files came from outside
this VM and an isolated interpreter cannot import a planted module out of the
working directory, so a stray `json.py` beside the input is not what
`import json` finds. **Read each file back with `json.load` right after writing
it**: a malformed artifact then fails here, where you can still fix it, instead
of downstream where you cannot.

```bash
python3 -I work/emit.py    # json.dump(obj, f, ensure_ascii=False, indent=2)
uv run --with jsonschema python -I work/validate.py "{{OUTPUT_DIR}}"/json/*.json
```

`ensure_ascii=False` keeps `Ibérica` legible rather than escaped. Write
`work/schema.json` with Python too (same reason), pinning all 16 top-level keys
`required`, `"additionalProperties": false` at every level, the `document_type`
enum, `^\d{4}-\d{2}-\d{2}$` on both dates, `^[A-Z]{3}$` on `currency`, and every
money field as `null` or an object of string `raw` and `value`.
`additionalProperties: false` is the one that earns its keep: a mistyped key is
otherwise a field that silently never arrives. Add the check jsonschema cannot
express — **every non-null field has an `evidence` entry, and `evidence` has no
key for a null field** — since an unquoted value is precisely the one nobody can
check. `validate.py` prints how many files passed and, per failure, the file and
the JSON pointer of the offending node. **A file that fails validation is still
delivered**, its errors named in the report: a consumer can skip a bad record
but cannot recover one you deleted.

**Slugs** for the filenames: lower-case the input's stem, accents to ASCII
(`Facturación` → `facturacion`), anything not a letter or digit to a hyphen,
collapse repeats, trim the ends. A second file reducing to the same slug gets
`-2`, or one overwrites the other and a document vanishes from a run that
reported it. `source_file` and the report carry the original name, so the
mapping is never lost.

**The arithmetic check**, per document and in `Decimal`: the sum of
`line_items[].amount` against `subtotal`, `subtotal + tax_amount` against
`total`, `quantity * unit_price` against `amount` on every line. A mismatch sets
`arithmetic_check` to a short description carrying **both** numbers (`"suma de
líneas 1.020,00 vs subtotal 1.002,00"`) and goes in the report. **Never edit a
number to make the sums work** — either the document is wrong or you misread a
line, and either way the discrepancy is the finding; correcting it silently
turns a document defect into a data error nobody can see.

## extracted.csv

Derived from `json/` and **built once, at the end**, by a script that globs
`{{OUTPUT_DIR}}/json/*.json`. Not appended to as you go: `claude` is retried up
to three times in this same workspace and a retry re-reads this file from the
top, so overwriting a per-document JSON is safe where appending a row is not — a
second attempt would duplicate every row. The JSON files are the source of
truth; the CSV is a view of them.

One row per document via `csv.writer` (its quoting handles the commas and
semicolons in vendor names) and `encoding="utf-8-sig"`, so a spreadsheet does
not mangle the accents. These columns, in this order:

```
source_file  slug  document_type  document_number  issue_date  due_date
currency  seller_name  seller_tax_id  buyer_name  buyer_tax_id  subtotal
tax_rate  tax_amount  total  line_item_count  fields_found  read_method
arithmetic_check
```

Monetary cells carry the normalised `value` so the column sums; a `null` field
is an empty cell. The CSV is **flattened and lossy by design** — the line items
and every `raw` string live only in the JSON. Say so in the report, so nobody
downstream mistakes the CSV for the record.

## Rules that matter

- **A field that is not in the document is `null`.** Never a guess, never a
  plausible default, never a value carried over from the previous document.
  Every non-null value must be quotable from the text you read, and `evidence`
  is where you quote it. A `null` is visible to the consumer; a fabricated
  invoice total is not, which makes it this task's worst possible output.
- **Keep every original string beside its normalised value**: the normalisation
  is a claim and `raw` is the proof.
- A document that is none of the five named kinds gets
  `document_type: "unknown"`, whatever fields genuinely apply, and a line in the
  report. It is not forced into the nearest shape.
- **Cover all {{INPUT_COUNT}} inputs** — extracted, skipped and failed alike. A
  file of the wrong type is not an error: skip it and list it.
- Install failures, unreadable files, empty extractions and your own doubts go
  in the report. An honest gap is worth more than a filled field.
- **Keep `{{OUTPUT_DIR}}/` clean**: only `json/`, `extracted.csv` and
  `EXTRACTION.md`. Everything else lives in `work/`.

## Required shape of `EXTRACTION.md`

1. **`# Extracción de campos`** (or the equivalent heading in {{LANGUAGE}}) — a
   paragraph: documents found, documents extracted, how many validated, how many
   failed the arithmetic check, and the most important anomaly.

2. **Per-document table** — one row per input file:

   | Archivo | Tipo | Campos | Método | Aritmética | Estado |
   |---|---|---|---|---|---|
   | factura-2026-0412.pdf | invoice | 18/21 | pdftotext -layout | OK | Extraído |
   | escaneo-albaran.pdf | delivery_note | 11/21 | page-images (2/2) | n/a | Extraído (transcrito) |
   | contrato.pdf | contract | 9/21 | pdftotext -raw | líneas 1.020,00 vs subtotal 1.002,00 | Revisar |
   | precios.xlsx | — | — | — | — | Omitido (no es un documento) |

3. **`## Ejemplo de registro`** — one complete JSON object, verbatim, in a fenced
   block: how the next reader learns the contract without rerunning the job.

4. **`## Campos no encontrados`** — field → how many documents lacked it, worst
   first. It is what tells whoever inherits this pipeline if it is good enough:

   | Campo | Documentos sin el campo |
   |---|---|
   | buyer.tax_id | 4 de 6 |
   | due_date | 3 de 6 |

5. **`## Comprobaciones aritméticas`** — every discrepancy with both numbers and
   its file. If every document checked out, say so explicitly.

6. **`## Problemas`** — unreadable files, empty extractions, ambiguous dates,
   validation errors with their JSON pointers, installs that failed. If there
   were none, say so rather than omitting the section.

7. **`## Herramientas utilizadas`** — one line per tool with the version you
   actually ran (`pdftotext -v`, `python3 -V`, `uv --version`, the resolved
   `jsonschema` and `pdfplumber` versions) and what each was for. It is how the
   next run knows what this took.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the counts
agree: {{INPUT_COUNT}} input file(s) → N documents in scope → N files in
`json/` → N data rows in `extracted.csv` → N rows in the per-document table,
with the number that passed validation stated plainly.
