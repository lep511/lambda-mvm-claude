<!--
Task library entry: faithful translation of every input document into
{{LANGUAGE}}. Two ways to use it —

  ./run-agent.sh --prompt prompts/translate-docs.md    # this run only
  cp prompts/translate-docs.md agent-prompt.md         # make it the default

Needs no rebuild and nothing beyond the execution role create-roles.sh builds:
the only I/O is INPUT_DIR and OUTPUT_DIR. poppler-utils is in the Dockerfile
and the HTML path is stdlib `html.parser`, so normally no Python library is
involved; the one the agent installs with uv, per run, is `charset-normalizer`.

Same contract as every task: input in INPUT_DIR, every artifact in OUTPUT_DIR.
What differs is that the artifact is the *whole* source document in another
language, so the risk is a plausible-looking shorter one, not a missing one.
It is the README's six-line "Making it do something else" sketch, done to the
library's standard.
-->

# Document translation job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Translate every document in `{{INPUT_DIR}}/` into **{{LANGUAGE}}**, leaving:

1. **`{{OUTPUT_DIR}}/translated/<slug>.md`** — one per input document: that
   document, whole, in {{LANGUAGE}}, as Markdown. The slug is the stem,
   lower-cased, accents stripped to ASCII (`Informe Q3 — Operación` →
   `informe-q3-operacion`), non-alphanumerics collapsed to one hyphen, always
   `.md`; a second input with the same slug gets `-2`, or one output is lost.
2. **`{{OUTPUT_DIR}}/TRANSLATION.md`** — the report, also in **{{LANGUAGE}}**.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

You handle `.pdf`, `.md`, `.txt` and `.html`. Anything else — a spreadsheet, an
archive, a video — is not an error and not your job: skip it and list it.

## The translation is the deliverable, not a summary of it

- Translate the **entire** document in its **original order**, preserving
  headings, lists, tables, code blocks, quotes and emphasis as Markdown.
- Do not condense, reorder, "improve" or annotate, and add no preface of your
  own: a reader diffing your `.md` against the source must find the same
  document, section for section.
- **Code, commands, identifiers and literal strings are copied, not
  translated** (see the glossary); a comment *inside* a code block may be, the
  code around it never.
- Where you could not read something, leave a marker line in its place
  (`> [no legible: página 7]`, in {{LANGUAGE}}) and list it in `## Problemas`.
- **State each document's source language from its text**, never from its name
  — `en-guide.md` written in Portuguese is a trap you walk into once — and if
  it is already in {{LANGUAGE}}, **copy it through unchanged** and record it as
  copied: round-tripping a document through its own language rewrites it for no
  gain and destroys the only cheap check anyone has on it. In a mixed document,
  translate what is not in {{LANGUAGE}} and say which parts already were.

This task does not fail by crashing. It fails as a long document whose first
sections are translated sentence by sentence and whose last third quietly
becomes a paraphrase, because by then the source is far back in context. So
work **section by section**: translate one, append it, move to the next.

```bash
OUT="{{OUTPUT_DIR}}/translated/informe-q3.md"
: > "$OUT"      # truncate first: `claude` is retried up to 3 times in this
                # same workspace and re-reads this prompt from the top, so an
                # append-only loop would deliver the document twice.
cat >> "$OUT" <<'MD'
## Resultados del trimestre
MD
```

Quote the delimiter (`<<'MD'`) every time: the text you append holds `$`,
backticks and backslashes, which an unquoted heredoc expands or executes. A
delimiter that occurs as a line of the text truncates the section silently.

## Extracting the text

One document at a time. Dumps go in `extracted/`, page images in `pages/`,
scripts in `scripts/` — all in the **workspace root**, never inside
`{{OUTPUT_DIR}}/`, which is uploaded verbatim: a forgotten scratch directory
ships as if it were the deliverable.

```bash
mkdir -p extracted pages scripts "{{OUTPUT_DIR}}/translated"
# .pdf — -layout keeps columns and table geometry; without it a two-column
# page interleaves its columns into nonsense, which you would then translate
# into fluent, plausible, wrong {{LANGUAGE}}.
pdftotext -layout "{{INPUT_DIR}}/informe-q3.pdf" extracted/informe-q3.txt
pdfinfo "{{INPUT_DIR}}/informe-q3.pdf"    # pages, for the inventory
# .md / .txt — no extraction: read them in place, in chunks.
# .html — write scripts/strip-html.py: an html.parser.HTMLParser subclass
# mapping h1..h6 to '#'*n, <li> to '- ' and <p>/<br>/<tr> to a blank line, and
# dropping everything between <script>/<style>, or a minified bundle lands
# mid-prose and you translate JavaScript. Leave convert_charrefs at its default
# so &amp; and &nbsp; arrive as characters.
python3 -I scripts/strip-html.py "{{INPUT_DIR}}/pagina.html" \
  > extracted/pagina.txt
```

`python3 -I` on anything that reads `{{INPUT_DIR}}/`: those files came from
outside this VM, and an isolated interpreter will not import a module out of
the working directory, so a planted `json.py` cannot be what `import json`
finds. A file that will not decode as UTF-8 is where a library earns its
install — `uv run --with charset-normalizer python scripts/encoding.py <file>`;
never `uv pip install --system`, which needs root. If that fails, use
`errors="replace"` and name the file in the report.

## Scanned PDFs

A PDF that extracts almost no text is a **rasterisation**: its pages are
images. Confirm it — an empty extraction can equally mean a wrong path.

```bash
pdffonts "{{INPUT_DIR}}/escaneado.pdf"         # no fonts -> no text layer
pdftoppm -r 150 -png -f 1 -l 4 "{{INPUT_DIR}}/escaneado.pdf" pages/escaneado
# -> pages/escaneado-01.png, ...   then Read each PNG in turn
```

There is no OCR engine here (`tesseract` is an apt package and you are not
root) and you need none: **you can read an image.** 150 dpi stays legible where
`pdfimages -j` would give 600 dpi for no extra readability. One page at a time,
and **transcribe into `extracted/<slug>.txt` first, then translate from the
transcription**: two lossy steps kept apart, and a source side left to compare
against. Bound a long scan with `-f`/`-l`, say how far you got, and label these
files transcribed *and* translated — weaker evidence than an extraction.

## Words that do not get translated

Keep a running list in `glossary.md` in the workspace root and carry it into
the report as a table. Localising `--dangerously-skip-permissions`, a JSON key
or a product name does not produce a worse translation — it produces an
artifact that breaks whatever reads it next. Left in the original: product,
company and project names; personal and place names with no established
{{LANGUAGE}} form; anything a machine reads — identifiers, filenames, CLI
flags, environment variables, API fields, HTTP headers, error codes, quoted
literals, units and their symbols. It is also how you stay **consistent** —
the same term the same way in section 1 and in section 40, across all
{{INPUT_COUNT}} documents; drift is the other fingerprint of this failure.

## Checking you did not drop anything

When a document is done, count its structure on **both** sides and compare: a
count that disagrees is the fingerprint of a dropped section, and the cheapest
way to catch the failure this prompt is built around. Write a short
`python3 -I` script that prints, per file, its ATX headings (`^#{1,6} `), list
items, pipe-table rows and non-empty lines, and `wc -c` both files for the
character ratio — opened with `errors="replace"`, because one bad byte must not
abort the check the honesty of the whole job rests on.

- Headings, list items and table rows must match **exactly** where the source
  carries Markdown (`.md`, `.html` after the stripper). Where it is a flat
  extraction there is no markup to count, so compare non-empty lines and the
  `wc -c` ratio: far shorter than the source is the summarised tail. Some pairs
  shrink legitimately (es → en by a tenth), so a low ratio is to be explained.
- **If a count disagrees, translate what is missing before writing the
  report**; a row that still disagrees is explained in `## Problemas`.

## Rules that matter

- **Never invent.** Every sentence answers to a sentence in text you extracted
  or a page you read. A file built from an assumption is worse than a missing
  one, because nothing downstream can tell the difference.
- **Truncate before appending**, so a retry rebuilds instead of doubling; and
  nothing in the glossary gets translated, two ways or at all.
- **Cover every file**: all {{INPUT_COUNT}} appear in the report, the ones
  copied unchanged, skipped and failed included.
- **Keep `{{OUTPUT_DIR}}/` clean** — only `translated/` and `TRANSLATION.md`;
  `extracted/`, `pages/`, `scripts/`, `glossary.md` stay in the workspace root.
- Failed installs, undecodable files, unread pages and doubts go in the report.

## Required shape of `TRANSLATION.md`

1. **`# Traducción de documentos`** (or the equivalent heading in {{LANGUAGE}})
   — a paragraph: how many files found, translated, copied unchanged as already
   in {{LANGUAGE}}, skipped or failed, and the target language.

2. **Inventory table**, one row per input file. `Método` is *how* the source
   text was obtained: a transcription is weaker evidence than an extraction.

   | Archivo de origen | Archivo traducido | Idiomas | Método | Págs./secs. | Estado |
   |---|---|---|---|---|---|
   | informe-q3.pdf | informe-q3.md | es → en | pdftotext -layout | 12 | Traducido |
   | escaneado.pdf | escaneado.md | fr → en | pdftoppm + lectura de páginas 1-4 | 4/12 | Traducido (transcrito, 4 de 12 páginas) |
   | guia.md | guia.md | en → en | lectura directa | 14 secs. | Copiado sin cambios (ya en el idioma destino) |
   | ventas.xlsx | — | — | — | — | Omitido (no es documento de texto) |

3. **Structural fidelity table** — the counts above, source → translation:

   | Archivo | Títulos | Viñetas | Tablas | Caracteres | Veredicto |
   |---|---|---|---|---|---|
   | guia.md | 14 → 14 | 63 → 63 | 2 → 2 | 41 208 → 44 517 (108 %) | Coincide |
   | informe-q3.pdf | — → 9 | — → 21 | — → 1 | 28 940 → 26 702 (92 %) | Origen plano: sin marcado que contar |
   | manual.md | 22 → 22 | 88 → 88 | 3 → 3 | 60 115 → 58 902 (98 %) | Coincide (3 secciones rehechas) |

4. **Glossary table** — `glossary.md`, tidied, plus any term whose
   {{LANGUAGE}} rendering you had to choose:

   | Término | Decisión | Motivo |
   |---|---|---|
   | --dangerously-skip-permissions | sin traducir | flag de CLI |
   | `"status": "ok"` | sin traducir | clave y valor de API |
   | panel de control | traducción de "dashboard" | elegida, usada en todo el lote |

5. **`## Problemas`** — every failure and doubt, grouped: empty extractions,
   undecodable files, unreadable pages, passages where the **source itself**
   was ambiguous and what you chose, rows that still disagree. If none, say so.

6. **`## Herramientas utilizadas`** — one line per tool with the version
   actually run (`pdftotext -v`, `python3 --version`, `uv --version` if used),
   what each was for, and any install that failed — how the next run knows.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the counts
agree: {{INPUT_COUNT}} input file(s) → N translated + N copied unchanged + N
skipped or failed, one `.md` per row not skipped, and every row explained.
