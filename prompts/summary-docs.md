<!--
Task library entry: PDF document summarisation — the task this lab shipped
with. Two ways to use it —

  ./run-agent.sh --prompt prompts/summary-docs.md    # this run only
  cp prompts/summary-docs.md agent-prompt.md         # make it the default

Needs poppler-utils in the image (pdftotext/pdfinfo), which is already in the
Dockerfile, so no rebuild is involved either way.

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

Work **one document at a time**: extract it, read the text, write down what you
learned, then move to the next. Put the intermediate `.txt` files in
`extracted/` in the workspace root — create it, and keep it out of
`{{OUTPUT_DIR}}/`, which is for finished artifacts only. For a long document,
read the extracted text in chunks rather than pulling the whole thing in at
once.

If a PDF yields little or no text, it is almost certainly a **scanned image**.
There is no OCR in this VM, so you cannot read it. Say so plainly in the
summary for that document and move on. Do **not** guess at its contents from
the filename.

## Rules that matter

- **Never invent content.** Every statement in the summary must come from text
  you actually extracted. If you could not read something, the summary says you
  could not read it.
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
   | example.pdf | 12 | Informe técnico | Procesado |
   | escaneado.pdf | 4 | — | Sin texto extraíble (escaneado) |

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
