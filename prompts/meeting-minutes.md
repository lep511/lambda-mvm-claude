<!--
Task library entry: meeting transcripts → minutes plus a machine-readable
action list. Two ways to use it —

  ./run-agent.sh --prompt prompts/meeting-minutes.md    # this run only
  cp prompts/meeting-minutes.md agent-prompt.md         # make it the default

Needs no rebuild and installs nothing: the standard library parses WebVTT and
SRT in twenty lines, and poppler-utils (for a PDF transcript) is in the image.

**No audio and no Transcribe.** "Meeting" invites a speech pipeline and a new
IAM grant; this is neither. The input is a transcript that already exists as
text, so nothing calls a speech service and nothing needs a grant beyond the
execution role create-roles.sh builds. With no `ffmpeg`, an `.mp3` is skipped.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. What differs: the input is *spoken*, mostly talk that concluded
nothing, and actions.csv is machine-readable, for loading into a tracker.
-->

# Meeting minutes job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Turn every meeting transcript in `{{INPUT_DIR}}/` into minutes:

1. **`{{OUTPUT_DIR}}/minutes/<slug>.md`** — one minutes document per meeting.
2. **`{{OUTPUT_DIR}}/actions.csv`** — every action from every meeting, header
   `source_file,timestamp,owner,action,due,status,confidence,quote`.
3. **`{{OUTPUT_DIR}}/MINUTES.md`** — the index and the cross-meeting view.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

Accepted: `.vtt`, `.srt`, `.txt`, `.md`, `.json` (an export with
speaker/start/text fields) and `.pdf`. Anything else is not an error and not
your job: skip it and list it.

Minutes and report go in **{{LANGUAGE}}**, whatever language the meeting was
held in — but **a quoted utterance stays verbatim in the original**, with a
translation beside it where needed: the quote is the evidence for the decision
it supports, and a translated quote cannot be checked against the transcript.

## Normalising the transcript first

Every citation in every deliverable hangs on a timestamp, so a normalisation
that drops them makes the whole job uncheckable. Do this first, before content.

```bash
mkdir -p work/norm work/notes   # workspace root, NOT in {{OUTPUT_DIR}}/
cat > normalise.py <<'PY'          # cue blocks -> "[HH:MM:SS] Speaker: text"
import re, sys
TAG = re.compile(r"<[^>]*>")            # <v Ana>, <c.loud>, <00:00:01.000>
WHO = re.compile(r"<v\s+([^>]*)>|^([^:]{1,40}):\s")   # both speaker forms
out = []                                # [HH:MM:SS, speaker, text]
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for block in re.split(r"\n[ \t]*\n", raw):
    lines = [l.strip() for l in block.splitlines() if l.strip()]
    cue = next((l for l in lines if "-->" in l), None)
    if cue is None: continue            # WEBVTT / NOTE / STYLE / cue number
    ts = cue.split("-->")[0].strip().replace(",", ".").split(".")[0]
    ts = ts if ts.count(":") == 2 else "00:" + ts   # VTT allows mm:ss.mmm
    text = " ".join(lines[lines.index(cue) + 1:])
    m = WHO.search(text)
    who = (m.group(1) or m.group(2)).strip() if m else None
    body = TAG.sub("", text).strip()
    if who and body.startswith(who + ":"): body = body[len(who) + 1:].strip()
    if not body: continue
    if out and out[-1][1] == who: out[-1][2] += " " + body   # same voice
    else: out.append([ts, who, body])
print("\n".join("[%s] %s: %s" % (t, w or "?", s) for t, w, s in out))
PY
# -I: the input came from outside this VM, so an isolated interpreter cannot
# import a planted json.py; errors="replace" so one bad byte cannot end it.
python3 -I normalise.py "{{INPUT_DIR}}/reunion-arq.vtt" \
  > work/norm/reunion-arq.txt
```

Merging cues from one voice into **one timestamp per utterance** is the point:
every citation hangs on that stamp. `.vtt` and `.srt` work as written; check
the first file's output before trusting it on the rest, which need one change
each:

- **`.json`** — check the first record's keys: exports disagree on
  `speaker`/`speaker_label` and on `start` in seconds or milliseconds.
- **`.txt` / `.md`** — no cues; keep any stamps (`[00:12]`). With none, cite by
  turn number (`turno 48`), labelled: an invented stamp is worse than a turn.
- **`.pdf`** — `pdftotext -layout "{{INPUT_DIR}}/x.pdf" work/norm/x.txt`.
- **`.mp3` / `.wav` / `.m4a` / `.mp4`** — skipped: no `ffmpeg`, no speech
  recogniser, none installable. Never "summarise" a file you could not hear.

`webvtt-py` exists (`uv run --with webvtt-py python …`), but the stdlib is the
default: fewer installs, fewer ways to fail. Never `uv pip install --system`,
which needs root.

## Working through it in wall-clock windows

A 90-minute transcript does not fit in context, and a summary of a summary
loses what this task is for: the commitments. So chunk by **wall-clock time,
not by lines** — a dense argument and a slide read-out are not comparable by
line count. Work in windows of **10–15 minutes**, writing each window's notes
(decisions, actions, questions, quotes + stamps) into
`work/notes/<slug>-00-15.md` before reading the next: the notes are the working
record, and the minutes are built from them at the end.

## What you may write down, and what you may not

Three categories, kept rigorously apart, because a brainstorm promoted to a
decision creates work nobody agreed to — the classic defect of these documents:

- A **decision**: the meeting concluded something. Who concluded it, when, its
  timestamp, and where it was contentious the verbatim quote as well.
- A **discussion**: positions aired, nothing concluded. Record who held what,
  and put anything you cannot categorise here.
- An **idea**: floated and not adopted, however good it was.

**An action needs an owner named in the transcript.** "Alguien debería mirar el
job" is an *unassigned* action: `owner` empty, `confidence: low`, never
attached to the most plausible attendee — that guess reads as a commitment from
someone who never made one. A due date is only a date if one was stated:
normalise an explicit date to ISO 8601 (`2026-10-17`), otherwise leave `due`
empty and let the quote carry the words ("antes del viernes", noting that the
absolute date is unknown). `quote` is there so every row can be checked without
trusting this document. `confidence`: **high** — owner and commitment both
explicit ("yo lo hago antes del jueves"); **medium** — owner clear, scope or
date fuzzy; **low** — implied, or no owner.

**Speaker labels are data, not names.** Diarised exports say `Speaker 1`,
`SPEAKER_00`, or a display name that is a device (`Sala 3`); use exactly what
the transcript says. If a speaker names themselves or is addressed by name the
mapping may be recorded as an **inference**, labelled as one, with the stamp it
came from (`Speaker 2 = ¿Marta? (inferido, 00:03:11)`) — inventing a surname
for `Speaker 2` is a fabricated attribution in a document that outlives the
meeting. Crosstalk, `[inaudible]`, truncated words and misheard names get the
same care: a figure heard once and never confirmed is **quoted and flagged**,
not adopted, because a wrong number in minutes gets cited for months.

## Naming the files, and writing `actions.csv` exactly once

Slug: lower-case, accents to ASCII (`revisión` → `revision`), anything not a
letter or digit to a hyphen, collapse repeats, trim the ends, collisions get
`-2`. If the transcript names the meeting and its date, the slug is the **ISO
date plus a short title** — `2026-10-08-revision-arquitectura.md` — because
`minutes/` sorts by name and readers expect chronology. The original filename
stays in the index table.

Write `actions.csv` **once, at the end, from `work/notes/`**, never appending
as you go: `claude` is retried up to three times on failure in this same
workspace and a retry re-reads this file from the top, so overwriting the
minutes is harmless but a second pass appending to the CSV duplicates every
commitment in whatever tracker loads it. Use `csv.writer`, never string joins:
`action` and `quote` come out of live speech and carry commas, quotes and
newlines, and this is the one file meant to be parsed by a machine.

## Rules that matter

- **Never invent.** Every decision, action and attribution cites a timestamp.
- **An unassigned action stays unassigned.** Empty `owner`, `confidence: low`.
- **Cover all {{INPUT_COUNT}} files** in the index, skipped and failed too.
- **Keep `{{OUTPUT_DIR}}/` clean** — only `minutes/`, `actions.csv` and
  `MINUTES.md`, because it is uploaded verbatim: a forgotten `work/norm/` there
  ships the operator the raw transcript instead of the minutes. Scratch and any
  script you write stay in `work/`, in the workspace root.
- Installs that failed, unreadable files and doubts go in `## Problemas`.

## Required shape of `minutes/<slug>.md`

1. **Title** — apparent name, date and span, then a one-paragraph summary.
2. **`## Asistentes`** — as labelled, inferences marked. **`## Agenda`** — as
   stated, or reconstructed and labelled "inferida".
3. **`## Decisiones`** — numbered, with stamps, and quotes where contentious.
4. **`## Acciones`** — this meeting's table:

   | # | Dueño | Acción | Vence | Confianza | Marca | Cita |
   |---|---|---|---|---|---|---|
   | 1 | Ana Pereira | Migrar facturación a la cola nueva | 2026-10-17 | high | 00:14:22 | «yo lo hago antes del jueves 17» |
   | 2 | — (sin dueño) | Revisar los reintentos del job | — | low | 00:41:05 | «alguien debería mirar el job» |

5. **`## Preguntas abiertas`**, **`## Desacuerdos`** (positions that did not
   converge, with who held them), **`## Ideas`**, and **`## Citas`**.

## Required shape of `MINUTES.md`

1. **`# Actas de reuniones`** (or the equivalent in {{LANGUAGE}}) — meetings
   processed, duration, utterances, decisions, actions, how many unassigned.
2. **Index table** — one row per meeting:

   | Acta | Archivo de origen | Duración | Voces | Decisiones | Acciones |
   |---|---|---|---|---|---|
   | 2026-10-08-revision-arquitectura.md | reunion-arq.vtt | 01:12:40 | 5 | 9 decisiones | 14 acciones (3 sin dueño) |

3. **The `actions.csv` contract** — the columns (`status` is `abierta` unless
   the transcript says otherwise), the `confidence` rubric, and two rows
   verbatim, so the next consumer needs no rerun to learn the format:

   ```csv
   source_file,timestamp,owner,action,due,status,confidence,quote
   reunion-arq.vtt,00:14:22,Ana Pereira,Migrar facturación a la cola nueva,2026-10-17,abierta,high,"yo lo hago antes del jueves 17"
   reunion-arq.vtt,00:41:05,,Revisar los reintentos del job,,abierta,low,"alguien debería mirar el job"
   ```

4. **`## Temas recurrentes`** — subjects raised in more than one meeting, and
   whether the position moved between them.
5. **`## Acciones sin dueño`** — every `owner`-empty row with its meeting and
   stamp. Those two sections are the whole reason a cross-meeting view exists.
6. **`## Problemas`** — files skipped and why, transcripts with no stamps,
   inaudible stretches, unresolved speaker labels, failed installs; if there
   were none, say so rather than omitting the section.
7. **`## Herramientas utilizadas`** — one line per tool, the version actually
   run (`python3 -V`, `pdftotext -v`, `uv --version`) and what it was for.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the counts
agree: {{INPUT_COUNT}} input file(s) → N minutes + M skipped → N rows in the
index → `actions.csv` rows = the sum of the per-meeting `Acciones` tables.
