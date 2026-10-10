<!--
Task library entry: PDF → Markdown, delivered to S3 and announced on SQS. Two
ways to use it —

  ./run-agent.sh --prompt prompts/pdf-to-markdown.md    # this run only
  cp prompts/pdf-to-markdown.md agent-prompt.md         # make it the default

Needs no rebuild and nothing added to the image: MarkItDown is a Python library,
so it is named below and the agent installs it itself with uv, inside the VM.
poppler-utils — the fallback converter and the scanned-PDF path — is already in
the Dockerfile.

It does need one grant the stock execution role does not ship with:
sqs:SendMessage on the queue named below. On this account it is there as the
AmazonSQSFullAccess managed policy attached to ClaudeAgentMicroVMExecutionRole,
which create-roles.sh knows nothing about: re-running that script keeps it (it
only rewrites the inline policy), but `--delete` followed by a recreate drops
it, and from then on every run converts perfectly and queues nothing. The
symptom is an AccessDenied on send-message, reported per file in CONVERSION.md.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. What is different here is that this task also writes to S3 and to
SQS *itself*, while it runs, instead of leaving the delivery to the runtime —
because a message that names an object has to be sent after that object exists.
See "Delivering to S3" below.
-->

# PDF to Markdown conversion job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Convert every PDF in `{{INPUT_DIR}}/` to Markdown. For **each** document that
you convert, produce three things:

1. **`{{OUTPUT_DIR}}/markdown/<slug>.md`** — the conversion.
2. **the same file in S3**, uploaded by you, at this run's own output prefix.
3. **one message on the SQS queue**, naming that object.

And for the human, one report: **`{{OUTPUT_DIR}}/CONVERSION.md`**, written in
**{{LANGUAGE}}**.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

Anything in there that is not a PDF is not an error and not your job: skip it
and list it in the report as not converted. One message per **converted**
file — never one for a file you skipped, and never one for `CONVERSION.md`
itself, which is for the human and not for the queue.

## Converting with MarkItDown

Use **MarkItDown** (Microsoft's `markitdown`). It is a Python library and **no
Python library is installed in this VM** — `python3` here is the bare standard
library, and you are not root — so install it yourself with `uv`, which is here
for exactly this. PDF support is an **extra**: plain `markitdown` resolves
without a PDF backend and fails on the first file with a missing-dependency
error, so always ask for `markitdown[pdf]`.

```bash
mkdir -p "{{OUTPUT_DIR}}/markdown"      # -o will not create the directory for you
uvx --from 'markitdown[pdf]' markitdown --version          # once, to warm the cache
uvx --from 'markitdown[pdf]' markitdown "{{INPUT_DIR}}/example.pdf" -o "{{OUTPUT_DIR}}/markdown/example.md"
```

That first call is not quick: MarkItDown sniffs file types through `magika`,
which pulls `onnxruntime` with it, so the install can take a minute and several
hundred megabytes. That is normal — let it finish. Do not abandon it and start
hand-rolling a converter. It caches, so every later file is fast.

If you would rather drive it from Python — to loop over the files, catch a
per-file failure and keep going — the library is the same one:

```bash
uv run --with 'markitdown[pdf]' python convert.py
# in convert.py:  from markitdown import MarkItDown
#                 MarkItDown().convert(path).text_content
```

Never `uv pip install --system`: it writes to `/usr/local/lib`, needs root, and
you are not root.

Two rules about the output itself:

- **The conversion is the deliverable, not a summary of it.** Keep MarkItDown's
  text as the body of the `.md`, in its original order. Do not paraphrase,
  condense, reorder or "improve" the prose, and do not add commentary. You may
  add a single `# Title` line at the top when the document's title is obvious,
  and nothing else. A reader diffing the `.md` against the PDF must find the
  same document.
- **If an install or a conversion fails, say so in the report** and move on to
  the next file. A `.md` you wrote from what you assumed the PDF said is worse
  than a missing one, because nothing downstream can tell the difference.

If `markitdown[pdf]` cannot be installed at all, `pdftotext -layout` is in the
image and is the honest fallback — the text will be flatter and have no
Markdown structure, so record `pdftotext` as the method for those files rather
than letting the report imply MarkItDown produced them.

## PDFs with no text layer

A PDF that converts to almost nothing — a page count in double digits and a few
hundred characters out — is usually a **rasterisation**: the pages are
page-sized images and there is no text to extract. Confirm that rather than
assuming it, because an empty conversion can equally mean a broken install:

```bash
pdfinfo          "{{INPUT_DIR}}/scan.pdf"   # page count, to compare against
pdffonts         "{{INPUT_DIR}}/scan.pdf"   # no embedded fonts -> no text layer
pdfimages -list  "{{INPUT_DIR}}/scan.pdf"   # one full-page image per page
```

There is no OCR engine here (`tesseract` is an apt package and you are not
root), and you do not need one: **you can read an image.** Rasterise the pages
at 150 dpi, read the PNGs, and write what you read as the Markdown body.

```bash
mkdir -p pages
pdftoppm -r 150 -png -f 1 -l 4 "{{INPUT_DIR}}/scan.pdf" pages/scan
# -> pages/scan-01.png, ...   then Read each PNG in turn
```

One page at a time, appending to the `.md` before rendering the next — ten page
images in context at once crowd out the transcription you still have to write.
Bound a long scan with `-f`/`-l` and state in the report how far you got.
`pages/` is scratch: it lives in the workspace root, **never** inside
`{{OUTPUT_DIR}}/`, which is uploaded verbatim — a forgotten `pages/` there
ships megabytes of PNGs as if they were the deliverable. Mark these files as
transcribed in the report, because a transcription and a MarkItDown conversion
are not the same evidence.

## Naming the markdown files

The name travels: it becomes the S3 key and the `name` field of the message, so
something other than a human will parse it. Derive the slug from the PDF's
stem — lower-case it, strip accents to ASCII (`caché` → `cache`), replace
anything that is not a letter, digit or dot with a hyphen, collapse repeated
hyphens and trim them from the ends:

```
El almacenamiento en caché … microservicios.pdf
  -> el-almacenamiento-en-cache-...-microservicios.md
Serverless Life _ DynamoDB Design Patterns for Single Table Design es.pdf
  -> serverless-life-dynamodb-design-patterns-for-single-table-design-es.md
```

If two PDFs reduce to the same slug, suffix the second `-2`: one key would
otherwise overwrite the other and you would queue two messages pointing at one
object. `CONVERSION.md` carries the original filename next to the slug, so the
mapping is never lost.

## Delivering to S3

The destination is this run's own output prefix, which is also where the runtime
will upload `{{OUTPUT_DIR}}/` when you are done. Writing the same key with the
same bytes is deliberate: the object exists the moment you need to name it in a
message, and the runtime's later upload is a no-op rewrite rather than a second
copy in a second place.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="lambda-mvm-claude-artifacts-${ACCOUNT}"
PREFIX="claude-agent/runs/{{RUN_ID}}/output"

# Confirm the bucket before relying on it: this run's prefix must list the
# prompt that was staged for it. A denied or empty listing means the bucket is
# not the default name, and everything below would fail one file at a time.
aws s3 ls "s3://${BUCKET}/claude-agent/runs/{{RUN_ID}}/"
```

Then, per converted file:

```bash
KEY="${PREFIX}/markdown/${SLUG}.md"
aws s3 cp "{{OUTPUT_DIR}}/markdown/${SLUG}.md" "s3://${BUCKET}/${KEY}" \
  --content-type "text/markdown; charset=utf-8"

# Ask S3 for the size instead of measuring the local file: this is the number
# that describes the object you are about to announce.
SIZE=$(aws s3api head-object --bucket "${BUCKET}" --key "${KEY}" \
  --query ContentLength --output text)
LOCATION="s3://${BUCKET}/${KEY}"
```

You hold `s3:GetObject` and `s3:PutObject` under `claude-agent/*` and **no
`s3:DeleteObject`** — there is no undo. Write only the files you mean to
deliver: no probe objects, no scratch, no "let me test whether this works"
upload, because whatever you put there stays there and lands in the operator's
download.

If the listing above fails, or an upload fails, **stop uploading and stop
sending messages**, but still leave every `.md` in `{{OUTPUT_DIR}}/markdown/`
so the runtime delivers the work, and write the report saying what failed and
that nothing was queued. Never send a message for a location you did not
successfully write.

## The SQS message

One message per converted file, to this queue:

```
https://sqs.us-east-1.amazonaws.com/024768456802/SalesQueue
```

The body is a JSON object with **exactly these three fields**, describing the
object in S3 — not the source PDF:

```json
{
  "name": "eventbridge-storming.md",
  "size": 48213,
  "location": "s3://lambda-mvm-claude-artifacts-024768456802/claude-agent/runs/<run-id>/output/markdown/eventbridge-storming.md"
}
```

- `name` — the basename of the object at `location`, slug plus `.md`.
- `size` — its size in bytes, as a **JSON number**, not a string. A consumer
  doing arithmetic on `"48213"` is a downstream bug you would have caused.
- `location` — the full `s3://bucket/key` URI you just wrote and confirmed.

No extra fields, no wrapper object, no array of all the files in one message.
The source PDF's own name and size belong in `CONVERSION.md`, not in the body.

**There is no `jq` in this image.** Build the JSON with `python3` and the
standard library, never by pasting strings into a template — these filenames
carry spaces, accents and underscores, and one quote or backslash in a name
turns a hand-built body into a message no consumer can parse. `-I` is there
because the files in `{{INPUT_DIR}}/` came from outside this VM: it stops the
interpreter importing anything out of the working directory, so a `json.py`
that arrived with the input cannot be what `import json` finds.

```bash
BODY=$(python3 -I -c '
import json, sys
print(json.dumps({"name": sys.argv[1], "size": int(sys.argv[2]), "location": sys.argv[3]}))
' "${SLUG}.md" "${SIZE}" "${LOCATION}")

MSG_ID=$(aws sqs send-message --region us-east-1 \
  --queue-url "https://sqs.us-east-1.amazonaws.com/024768456802/SalesQueue" \
  --message-body "${BODY}" --query MessageId --output text)
```

`--region us-east-1` explicitly, because the queue URL names that region and
this VM's own region is not guaranteed to match it; signing for the wrong
region is a confusing failure for something this simple. It is a **standard**
queue, so no message group or deduplication id is needed — if a send ever comes
back asking for a `MessageGroupId`, someone replaced it with a FIFO queue and
the report should say so.

### Order, and why it is not negotiable

Per file: **convert → upload → `head-object` → `send-message`.** The message is
a promise that the object is there, and the queue may be drained the instant it
arrives; sent before the upload lands, it hands a consumer a 404 for an object
that will exist a second later — the hardest kind of bug to see from either end.

### Sending exactly once

`claude` is retried up to three times on failure, in this same workspace, and a
retry re-reads this file from the top. If the second attempt converts and
queues everything again, the downstream consumer sees every document twice.
Leave yourself a receipt so a retry can tell what is already done:

```bash
mkdir -p sent                 # workspace root — scratch, NOT in {{OUTPUT_DIR}}/
# inside your per-file loop:
[[ -f "sent/${SLUG}" ]] && continue          # already uploaded and queued
# ... upload, head-object, send-message ...
printf '%s\n%s\n' "${MSG_ID}" "${BODY}" > "sent/${SLUG}"
```

One receipt per slug, the id on the first line and the body on the second, so
the message table in the report can be rebuilt from `sent/` even if the attempt
that sent them was the one that died.

Do not use the queue's own `ApproximateNumberOfMessages` to check your work: it
is approximate, and a consumer reading the queue makes it drop. The `MessageId`
that `send-message` returns is the only proof you have that a message was
accepted, which is why every one of them goes in the report.

## Rules that matter

- **Never invent content.** Every line of every `.md` comes from MarkItDown's
  output, from `pdftotext`, or from a page image you actually read.
- **Cover every file.** All {{INPUT_COUNT}} appear in the report, including the
  ones you skipped and the ones that failed.
- **Counts must agree**: converted files = objects in S3 = messages sent. If
  they do not, the report says which file broke the chain and where.
- **Keep `{{OUTPUT_DIR}}/` clean.** Only `markdown/` and `CONVERSION.md`.
  Scratch (`sent/`, `pages/`, any script you write) lives in the workspace root.

## Required shape of `CONVERSION.md`

1. **`# Conversión de PDF a Markdown`** (or the equivalent heading in
   {{LANGUAGE}}) — a short paragraph: how many PDFs were found, how many were
   converted, how many messages reached the queue, and anything that failed.

2. **Conversion table** — one row per input file:

   | Archivo de origen | Markdown | Método | Páginas | Estado |
   |---|---|---|---|---|
   | EventBridge Storming.pdf | eventbridge-storming.md | markitdown[pdf] | 32 | Convertido |
   | escaneado.pdf | escaneado.md | pdftoppm + lectura de páginas 1-4 | 12 | Convertido (transcrito, 4/12 páginas) |
   | notas.txt | — | — | — | Omitido (no es PDF) |

   `Método` is how the Markdown was produced, not merely that it was: a
   transcription from page images is weaker evidence than an extraction, and
   the reader checking a passage needs to know which one they have.

3. **Message table** — one row per message actually sent, with the three fields
   as they went on the wire plus the id that came back:

   | name | size | location | MessageId |
   |---|---|---|---|

4. **`## Mensaje de ejemplo`** — the body of one message, verbatim, in a JSON
   block. It is how the next reader learns the contract without rerunning the
   job.

5. **`## Problemas`** — every failure and every doubt, grouped: installs that
   failed, PDFs with no text layer, pages you could not read, uploads or sends
   that were denied. If there were none, say so explicitly rather than omitting
   the section.

6. **`## Herramientas utilizadas`** — one line per tool, with the version you
   actually ran (`markitdown --version`, `uv --version`, `pdftotext -v`) and
   what each was for. It is how the next run of this task knows what it took.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the three
counts match: {{INPUT_COUNT}} input file(s) → N converted → N objects in S3 →
N messages with a `MessageId`.
