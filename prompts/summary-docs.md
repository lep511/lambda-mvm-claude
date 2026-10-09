<!--
Task library entry: PDF document summarisation — the task this project shipped
with. Two ways to use it —

  ./run-agent.sh --prompt prompts/summary-docs.md    # this run only
  cp prompts/summary-docs.md agent-prompt.md         # make it the default

Needs poppler-utils in the image (pdftotext/pdfinfo, and pdftoppm for the
scanned-PDF path below), which is already in the Dockerfile, so no rebuild is
involved either way. It is in the image because it is an apt package and the
agent is unprivileged; Python libraries are NOT in the image and the agent
installs those itself with uv.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. This one produces a single SUMMARY.md.
-->

# Document summarisation job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the result in `{{OUTPUT_DIR}}/`.

## Your task

Read every document in `{{INPUT_DIR}}/` and write **one file:
`{{OUTPUT_DIR}}/SUMMARY.md`**.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

Write the summary in **{{LANGUAGE}}**, regardless of the language the source
documents are written in.

## Reading PDFs

`pdftotext` and `pdfinfo` (poppler) are installed. Use them — do not try to
read a `.pdf` as if it were text.

```bash
pdfinfo  "{{INPUT_DIR}}/example.pdf"                      # pages, title, metadata
pdftotext -layout "{{INPUT_DIR}}/example.pdf" "extracted/example.txt"
```

Those two are command-line tools baked into the image. **No Python library is**
— `python3` here is the bare standard library — so if you want one (`pypdf` for
page-level work, `pdfplumber` for tables), install it yourself with `uv`, which
is here for that: `uv run --with pypdf python script.py`, or `uvx <tool>` for a
command. Never `uv pip install --system`: it needs root and you are not root.

Work **one document at a time**: extract it, read the text, write down what you
learned, then move to the next. Put the intermediate `.txt` files in
`extracted/` in the workspace root — create it, and keep it out of
`{{OUTPUT_DIR}}/`, which is for finished artifacts only. For a long document,
read the extracted text in chunks rather than pulling the whole thing in at
once.

## PDFs with no text layer

A PDF that yields little or no text is a **rasterisation**: the pages are
page-sized images and there is nothing to extract. Confirm it rather than
assuming it, because an empty extraction can also be a wrong flag or a wrong
path:

```bash
pdffonts        "{{INPUT_DIR}}/scan.pdf"   # no embedded fonts -> no text layer
pdfimages -list "{{INPUT_DIR}}/scan.pdf"   # one full-page image per page
```

There is no OCR engine here — `tesseract` is an apt package and you are not
root, so no amount of `uv` will get you there. You do not need one: **you can
read an image.** Rasterise the pages and read the PNGs; the transcription is
your extracted text.

```bash
mkdir -p pages
pdftoppm -r 150 -png -f 1 -l 4 "{{INPUT_DIR}}/scan.pdf" pages/scan
# -> pages/scan-01.png, pages/scan-02.png, ...   then Read each PNG in turn
```

`pdftoppm` ships in the same poppler package as `pdftotext`, so it is already
here. `pages/` is scratch exactly like `extracted/`: workspace root, **never**
inside `{{OUTPUT_DIR}}/`, which is uploaded verbatim — a forgotten `pages/`
there ships megabytes of PNGs as if they were the deliverable.

What makes the difference between this working and it eating the run:

- **Render at 150 dpi, and never use `pdfimages -j`.** 150 dpi is about
  1240x1754 px for an A4 — comfortably legible, roughly 3k tokens of image.
  `pdfimages` extracts the embedded scan at its native resolution instead,
  often 600 dpi, which is an order of magnitude more image for no extra
  readability.
- **One page at a time**, writing what you read into `extracted/<file>.txt`
  before rendering the next. Read ten PNGs first and the transcription you
  still have to write is competing for context with ten page images.
- **Bound it with `-f`/`-l`.** A long scan does not have to be transcribed in
  full for the summary to be honest — do the pages that carry the content and
  state how far you got.
- If a page is genuinely illegible — bad scan, handwriting, a script you cannot
  read — say that for that page. Reading an image is still reading; inferring
  from the filename is not.

Transcribing is reading, so the document gets a full section like any other.
But it is weaker evidence than extracted text, so label it: the inventory row
says how it was read, and so does any figure you lift from it.

## Rules that matter

- **Never invent content.** Every statement in the summary must come from text
  you extracted or a page image you actually read. If you could not read
  something, the summary says you could not read it.
- **Attribute everything.** Each claim names the file it came from, so a reader
  can go check it.
- **Cover every file.** All {{INPUT_COUNT}} get a section, including the ones
  that failed to extract.
- Be specific over generic: concrete figures, names, dates and conclusions beat
  "the document discusses several topics".

## Required shape of `SUMMARY.md`

1. **`# Resumen de documentos`** (or the equivalent heading in
   {{LANGUAGE}}) — a short paragraph: how many documents, what they are
   collectively about, and the single most important takeaway.

2. **Inventory table** — one row per file:

   | Archivo | Páginas | Tipo | Estado |
   |---|---|---|---|
   | example.pdf | 12 | Informe técnico | Procesado (pdftotext) |
   | escaneado.pdf | 4 | Artículo | Escaneado: transcrito leyendo las páginas 1-4 |

   `Estado` says **how** the document was read, not just whether it was: a
   transcription from page images and a `pdftotext` extraction are not the same
   evidence, and the reader checking a figure needs to know which one it is.

3. **One `##` section per document**, named after the file. For each: what it
   is, its purpose and audience, the key points as a bullet list, and any
   figures, dates or conclusions worth carrying forward.

4. **`## Síntesis transversal`** (or the equivalent) — this is the part a
   per-file summary cannot give you, so do not skip it:
   - themes that recur across documents, and which files share them
   - where documents **contradict or disagree** with each other
   - gaps: what the set as a whole does not cover
   - if the documents are sequential (versions, dates), how the picture evolves

Finish by confirming `{{OUTPUT_DIR}}/SUMMARY.md` exists and is complete. It is
the only artifact that leaves this VM.
