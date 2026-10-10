<!--
Task library entry: input documents → a presentation. Two ways to use it —

  ./run-agent.sh --prompt prompts/deck-outline.md    # this run only
  cp prompts/deck-outline.md agent-prompt.md         # make it the default

One optional variable, the audience, which changes the output more than anything
else here. Without it the agent infers one, labels it, and carries on:

  ./run-agent.sh --prompt prompts/deck-outline.md \
      --var AUDIENCE="comité técnico"

No rebuild and nothing added to the image: pdftotext (poppler-utils) is in the
Dockerfile, the extraction is summary-docs.md's, no Python library, and the
optional HTML render comes from `npx @marp-team/marp-cli` at run time. Nothing
beyond the execution role create-roles.sh builds either: it reads INPUT_DIR,
writes OUTPUT_DIR, calls no AWS API of its own.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. What differs is the artifact — summary-docs.md turns this input into
one cross-referenced summary; this turns it into a deck, with a slide budget,
speaker notes and per-slide provenance.
-->

# Deck outline job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Turn the documents in `{{INPUT_DIR}}/` into **one presentation**. Deck and
report are both written in **{{LANGUAGE}}**, whatever language the sources are:

1. **`{{OUTPUT_DIR}}/DECK.md`** — the whole deck in one markdown file: YAML
   front matter, slides separated by a `---` on its own line, speaker notes as
   HTML comments under each. Marp and `pandoc -t beamer` both read that
   convention, so the deck is usable without this project.
2. **`{{OUTPUT_DIR}}/slides/NN-<slug>.md`** — the same slides, one file each,
   zero-padded and in deck order, so a human can reorder the deck or hand one
   slide to a colleague without touching the rest.
3. **`{{OUTPUT_DIR}}/DECK-NOTES.md`** — the report: where each slide came from.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

**There is no `.pptx` writer here** — no `pandoc`, no LibreOffice, nothing
installable without root. Do not go looking; the markdown is what ships.

## Who the deck is for

The deck is pitched at: **{{AUDIENCE}}**.

It decides depth, vocabulary and what counts as obvious. If the line above still
reads literally `{{AUDIENCE}}`, no value was passed — the runtime only logs a
warning and hands you the placeholder. Then infer the audience from the
documents, **say so on the first line of `DECK-NOTES.md`** ("inferido de los
documentos: dirección técnica"), and carry on. Never stop over this, and never
write as if a value had been given.

## Reading the documents

Extract **one document at a time** into a scratch `extracted/`, noting each
before the next: slide titles come out of those notes, and without them the
deck's themes blur into an average of what you half-remember.

```bash
pdfinfo "{{INPUT_DIR}}/example.pdf"                        # pages, title
pdftotext -layout "{{INPUT_DIR}}/example.pdf" extracted/example.txt
```

`-layout` keeps columns and tables roughly where they were, which is what makes
a figure on a slide traceable to its page. `.md`, `.txt` and `.csv` read
directly, `html.parser` strips tags from `.html`: **nothing needs installing**.

A PDF yielding little or no text has no text layer: confirm it rather than
assume it, with `pdffonts` (no embedded font) and `pdfimages -list` (one image
per page). Then rasterise with `pdftoppm -r 150 -png` into a scratch `pages/`
and read the PNGs one at a time — you are a vision model and there is no OCR
engine here. Mark the slides they feed `(transcrito)`: weaker evidence.

`extracted/`, `pages/` and any script you write live in the **workspace root**,
never in `{{OUTPUT_DIR}}/`, which is uploaded verbatim — a forgotten `pages/`
there ships megabytes of PNGs as if they were the deck. Any script reading the
input runs as **`python3 -I`**: that input came from outside this VM, and an
isolated interpreter cannot import a module planted in the working directory.

## The arc is fixed, the length is not

Título · Agenda · Contexto/problema · **N diapositivas de contenido** ·
Conclusiones · a closing **`## Fuentes`** slide naming every file in
`{{INPUT_DIR}}/`, used or not.

N follows from the material: roughly one slide per substantive theme, **8 to
20** content slides for a normal input set. Put the number you chose, and why,
in the report — padding to a round twenty is padding, and sixty slides from
three documents is a wall of text with page breaks. Within a slide, the limits
are numbers rather than guidelines, because prose belongs in the notes:

- **Title: at most 8 words, and a claim rather than a topic** — "El coste se
  concentra en 3 consultas", not "Costes". A topic title makes the audience hunt
  for the point; a claim title *is* the point, and is what makes the provenance
  table checkable.
- **At most 6 bullets, at most 12 words a bullet.** No paragraph anywhere on a
  slide, no nesting deeper than one level.
- **Every number carries its unit** (`1.240 €/mes`, `37 %`, `12 días`) and its
  source document in the notes. A bare number gets quoted unchecked.
- **A table: at most 4 columns and 6 rows** — bigger goes in the notes, with its
  own source. **A quote is verbatim**, with file and page, never tidied up.
- **No images are embedded**: a `![](…)` pointing at a path that does not ship
  is a broken deck the moment anyone renders it. If a figure inside a PDF
  matters, the slide says so in words and the notes name its page.

Under each slide, between `<!--` and `-->`, the notes: what the presenter should
say, then one `Fuente: <archivo>, p. <página>` line of its own per claim on that
slide. That is what makes the deck checkable and its only defence against
invention — a claim with no `Fuente:` line is one you made up. Never put a line
that is exactly `---` inside a slide or a note: Marp reads it as a break, and so
does the split below.

## `DECK.md` first, `slides/` derived from it

`DECK.md` is the source of truth; write it by hand. Front matter once, at the
top: `marp: true`, `paginate: true`, a `title` that is the deck's claim, and a
generic `author` (`Equipo de análisis`) — no real name on a deck an agent wrote.

Then **generate** `slides/` with a short `python3 -I` script rather than writing
both by hand, or the two will disagree about how many slides exist — the first
defect a reader finds. The script: delete `{{OUTPUT_DIR}}/slides` and recreate
it, because `claude -p` is retried up to three times **in the same workspace**
and re-reads this prompt from the top, so a leftover `slides/14-*.md` can ship
beside a nine-slide deck; drop the front matter and split the rest on
`"\n---\n"`, exactly that, since a `---` with trailing spaces or a `----` rule
is no slide break for Marp either; write each block verbatim, byte-identical by
construction, not by diligence; name it `NN-<slug>.md`: the index zero-padded,
and the slug the title, accents folded to ASCII and the rest turned to hyphens.

Then check the counts rather than trusting them:

```bash
# N slides = 2 front-matter fences + N-1 separators, so SEPS - 1
SEPS=$(grep -c '^---$' "{{OUTPUT_DIR}}/DECK.md")
echo "DECK.md=$(( SEPS - 1 ))  slides/=$(ls -1 "{{OUTPUT_DIR}}/slides" | wc -l)"
```

`'^---$'` is anchored at both ends: only a line that is nothing but a separator
counts. If the two disagree, `slides/` is stale — fix it before the report.

## The optional HTML render — last, once, never fatal

Only after the markdown is final, and only once:

```bash
timeout 300 npx --yes @marp-team/marp-cli@latest \
  "{{OUTPUT_DIR}}/DECK.md" -o "{{OUTPUT_DIR}}/deck.html"
```

That is one self-contained HTML deck, openable with no server. `npx` works here
even though `npm install -g` does not: the global install needs root, while
`npx` caches under `$HOME/.npm` (`HOME=/home/agent`), which is writable. It may
fail — a large download, breaking for reasons unrelated to your job — so
**never ask for `-o deck.pdf`**, which drives a headless Chromium this image
does not have. On failure, record it under `## Problemas` and delete the partial
file (`grep -q '</html>' deck.html || rm -f deck.html`): a truncated HTML file
in `{{OUTPUT_DIR}}/` is uploaded like everything else and looks like a deck.

## Rules that matter

- **Never invent anything.** Every claim traces to a document you read, named
  in its `Fuente:` line with the page or section. A slide is the most quotable
  artifact here and the least checked, so a fabricated figure is worst of all.
- **Cover every input.** All {{INPUT_COUNT}} are either represented in the deck
  or listed in the report as not used, with the reason — a document you could
  not read never gets a slide implying that you read it.
- **The deck is one argument**, not {{INPUT_COUNT}} summaries stapled together:
  where two documents disagree, that disagreement is a slide, with both sources.
- **`{{OUTPUT_DIR}}/` holds only** `DECK.md`, `slides/`, `DECK-NOTES.md`, and
  `deck.html` if the render worked; the rest is scratch, in the workspace root.
- **Say what went wrong**: unreadable files, empty extractions, a failed install
  or render, a claim you could support only weakly. Silence reads as success.

## Required shape of `DECK-NOTES.md`

1. **`# Notas del mazo`** (or the equivalent heading in {{LANGUAGE}}) — one
   paragraph: how many documents you read, how many slides and why that many,
   who the deck is for (the inference, labelled as one, if `{{AUDIENCE}}` was
   not supplied), and the single message the deck is built around.

2. **Procedencia**, one row per slide — the point of this file:

   | # | Título | Fuentes | Cómo se leyó |
   |---|---|---|---|
   | 04 | El coste se concentra en 3 consultas | informe-costes.pdf, p. 12-14 | pdftotext |
   | 09 | El pilotaje terminó en marzo | acta-escaneada.pdf, p. 2 | pdftoppm (transcrito) |

   **Every** slide gets a row, título, agenda and `Fuentes` included.

3. **Inventario de documentos**, one row per input file:

   | Archivo | Cómo se leyó | Diapositivas | Estado |
   |---|---|---|---|
   | informe-costes.pdf | pdftotext -layout | 04, 05, 07 | Procesado (18 p.) |
   | acta-escaneada.pdf | pdftoppm -r 150, p. 1-4 | 09 | Transcrito (4/12 p.) |
   | anexo.pdf | — | — | Sin capa de texto, páginas ilegibles |

4. **`## Qué quedó fuera`** — material you read and deliberately did not use,
   and why. This is where a deck earns trust with a reader who knows a source.

5. **`## Problemas`** — files you could not read, empty extractions, the render
   if it failed, claims you could support only weakly. None? Say so.

6. **`## Herramientas utilizadas`** — one line per tool, the version you ran
   (`pdftotext -v`, `python3 -V`, `npx @marp-team/marp-cli --version`), what it
   was for, and anything that failed. How the next run knows what this took.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the counts
agree: {{INPUT_COUNT}} input file(s) → N represented + M listed as unused, and
one single slide count across `DECK.md`, `slides/` and the provenance table.
