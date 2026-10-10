<!--
Task library entry: log triage — collapse a pile of log files into the handful
of distinct problems a human can act on. Two ways to use it —

  ./run-agent.sh --prompt prompts/log-triage.md    # this run only
  cp prompts/log-triage.md agent-prompt.md         # make it the default

Needs no rebuild and installs nothing — the standard library covers this job end
to end (`re`, `gzip`, `json`, `csv`, `collections`, `datetime`) — and nothing
beyond the execution role create-roles.sh builds. In particular it does **not**
query CloudWatch Logs: the logs are files in INPUT_DIR, staged like any other
input, so a `logs:StartQuery` grant handed to this task is a misreading.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR; what is different is that nearly every figure comes out of a script
written on the spot and kept in the workspace, so any number can be rederived.
-->

# Log triage job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Triage every log file in `{{INPUT_DIR}}/` and leave **three artifacts**:

1. **`{{OUTPUT_DIR}}/TRIAGE.md`** — the report, written in **{{LANGUAGE}}**.
2. **`{{OUTPUT_DIR}}/errors.csv`** — every distinct error signature, header
   `signature,level,count,first_seen,last_seen,example_file,example_line,example_text`
3. **`{{OUTPUT_DIR}}/timeline.csv`** — header `bucket_utc,file,level,count`,
   so the volume over time can be plotted by something other than a human.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

Plain text logs, JSON lines, syslog and Apache/nginx access logs are in scope,
gzipped or not; anything else is not an error — skip it and say what it is.

## Reading the files

Scripts you write and anything you extract go in **`work/`** in the workspace
root — create it. `{{OUTPUT_DIR}}/` is uploaded verbatim, so a decompressed copy
left there ships as the deliverable: a 2 GB `.log` unpacked into it is 2 GB of
upload and a reader who cannot find the report. You rarely need to decompress at
all — `gzip.open`, `bz2.open` and `lzma.open` stream in `"rt"`.

Run anything that reads `{{INPUT_DIR}}/` as **`python3 -I`**: those files came
from outside this VM, and an isolated interpreter will not import from the
working directory, so a `json.py` that arrived with the input cannot be what
`import json` finds. Pass **`errors="replace"`** on every open, since one
invalid UTF-8 byte in a ten million line file otherwise ends the job at 60 %
with `UnicodeDecodeError` — count the lines it mangles and report the number.
Iterate the handle rather than `.read()`, which on a multi-gigabyte log is an
OOM. And **`jq` is not in this image**, so JSON lines are Python and not a
shell pipeline — `json.loads` per line in a `try`, where a line that does not
parse is an *unparsed line* and not a traceback. The stdlib is enough for all
of it; reach for `duckdb` or `polars` (`uv run --with <lib>`, never
`--system`, which needs root) only when the volume justifies it, and say in the
report which you used.

## Detect the format by sampling, and report what did not parse

Decide from the first ~50 non-blank lines of each file, **not from the
extension**: a `.log` is routinely JSON lines and a `.txt` routinely an access
log, and a parser pointed at the wrong format does not raise — it matches
nothing and reports **zero errors**, the most dangerous output this task can
produce. Classify as `JSON lines`, `access log` (combined/common), `syslog`,
`timestamped text` or `unknown` and record the format **and the confidence**
(share of sampled lines matched); below ~80 %, say so rather than force it.

**Unparsed lines are reported, never dropped**: count them per file, keep three
examples each, and print the number beside the parsed count in the inventory.
Skipping what the regex missed is how a triage report comes out clean while the
service is on fire, and it is invisible — those are the lines you never saw.

## Error-signature clustering

This is what turns 40 000 error lines into the twelve problems a human can act
on, so it gets the most care — and it counts **events, not lines**, since a
stack trace is one event and treating it as forty inflates every figure in the
report by the average trace depth. A line **starts** an event if it matches the
file's line shape (timestamp, syslog header, JSON object) and otherwise
**continues the previous one**: whitespace-led lines, `at `, `Caused by:`,
`Traceback (most recent call last)`, and anything the line regex rejects while
an event is open. A multi-line event's signature is the **first line plus the
deepest frame in the application's own code** (the first frame outside
`site-packages`, `node_modules`, `/usr/lib/python*`, `java.base/` or a
framework package; the deepest overall if all are library code): the whole
trace as a key splits one bug raised from forty call sites into forty problems,
the first line alone merges forty distinct bugs into one.

Then collapse each message by replacing everything that varies, in **this
order** — order is not cosmetic: replace bare integers first and a UUID becomes
`<NUM>-<NUM>-<NUM>-<NUM>-<NUM>`, clustering nothing.

```python
SUBS = [                       # applied in order, each with re.IGNORECASE
    (r'\b(?:req|request|trace|span|corr)[-_ ]?id\s*[=:]\s*\S+', '<REQID>'),
    (r'\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.,\d]*(?:Z|[+-]\d\d:?\d\d)?', '<TS>'),
    (r'\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b', '<UUID>'),
    (r'\b(?:\d{1,3}\.){3}\d{1,3}\b', '<IP>'),
    (r'\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}\b', '<IP6>'),
    (r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b', '<EMAIL>'),
    (r'\bhttps?://[^\s"\'<>]+', '<URL>'),         # query string included
    (r'\b0x[0-9a-f]+\b', '<ADDR>'), (r'\b[0-9a-f]{12,}\b', '<HEX>'),
    (r'(?<![\w.])/[\w./@%+-]{2,}', '<PATH>'), (r'"[^"]*"|\'[^\']*\'', '<STR>'),
    (r'(?<![\w.])-?\d+(?:\.\d+)?', '<NUM>'),   # no trailing \b: 512Mi -> <NUM>Mi
]
```

`re.sub` each pair over the message in that order, collapse runs of whitespace,
then **keep the first 160 characters** and not the whole collapsed form:
messages differ in their tails far more often than in what is wrong, so an
untruncated key quietly splits one cluster into many. `<STR>` runs **last and
deliberately swallows what is already tokenised** — access-log request lines
are the exception, parsed into method/path/status *first* with the path
normalised yourself (`/users/<NUM>`). The `signature` column holds that
**readable collapsed text**, not a hash a human cannot triage; and **list the
substitutions in the report**, because a scheme nobody can see is a number
nobody can check.

## Timestamps, levels and access logs

`datetime.fromisoformat` for ISO-8601, `datetime.strptime` with a short list of
the formats you saw while sampling (`%d/%b/%Y:%H:%M:%S %z` for access logs,
`%b %d %H:%M:%S` for syslog). Normalise to UTC where an offset is present;
where there is **none**, label that file's times local/unknown rather than
assume this VM's clock applies, because a quietly shifted window invents a
correlation that is not there. Bucket per **hour**, or per **minute** if the
window is under two hours, since an hourly bucket over a 40-minute incident is
one bar — one `timeline.csv` row per `(bucket, file, level)` with a non-zero
count. Report the window per file and overall; **clock skew**, as a pair of
files whose windows should overlap and do not plus the offset measured; and
**gaps** from the bucket series, because an hour with zero lines in a file that
otherwise logs continuously is a finding (process died, disk full, shipper
stopped) and not a quiet period.

For levels, recognise `TRACE DEBUG INFO NOTICE WARN WARNING ERROR ERR SEVERE
CRIT CRITICAL FATAL ALERT EMERG PANIC`, their lower-case forms and the syslog
numeric priority (`<134>` → severity 6 → `INFO`; 0-7 maps EMERG..DEBUG), and
fold unrecognised labels into **`OTHER` with a count**, naming them — dropping
them loses a service's whole logging convention. For access logs, from a script
and never eyeballed: the status-code histogram by class and exact code, top
paths by 5xx (normalised, so `/users/42` and `/users/43` are one path), top
client addresses by error count, and the slowest requests if a duration field
exists — settle its unit first, since `%D` is microseconds where
`$request_time` is seconds.

## Redaction, and it is not optional

Logs carry bearer tokens, passwords in query strings, API keys, session cookies,
card numbers, emails and personal data, and `{{OUTPUT_DIR}}/` is uploaded and
then shared with people who were never meant to see any of it. So write **one**
`redact(text)` in `work/` and put every line you quote through it — the report
and `example_text` in `errors.csv` alike, because one function is one place
that can be wrong.

When a secret-shaped value appears the report names the **file, the line number
and the kind** of secret and quotes **at most the first four characters** of the
value (`eyJh…`, `AKIA…`): enough for an on-call engineer to match it against
what they are rotating, without the value leaving with the report. Look for
`Authorization: Bearer`, `password|passwd|pwd=`, `api[-_]?key=`, `token=`,
`Set-Cookie:`/`session(id)?=`, `(AKIA|ASIA)[0-9A-Z]{16}`, `-----BEGIN ... KEY`,
JWTs (`eyJ`), emails and 13-19 digit runs — and **Luhn-check the digit runs**
first, because a 16-digit order id reported as a leaked PAN is a false alarm,
and a report that cries wolf once is ignored for real findings.

## Rules that matter

- **Never invent a number.** Every count, rate and window comes out of a script
  you ran, kept in `work/` so it can be rederived. A total extrapolated from a
  sample and called a total is the central failure of this task: say you
  sampled, say how much, and call the figure an estimate.
- **Cover all {{INPUT_COUNT}} inputs**, the skipped and the unreadable included,
  and put install failures and leftover doubts in `## Lagunas`.
- **`{{OUTPUT_DIR}}/` holds the three artifacts only** — scripts, extractions
  and any decompressed copy live in `work/`.
- **Write the three artifacts whole, never append.** `claude` is retried up to
  three times in this same workspace and a retry re-reads this file from the
  top: overwriting is safe, appending to `errors.csv` doubles every count.

## Required shape of `TRIAGE.md`

1. **`# Triaje de logs`** (or the equivalent heading in {{LANGUAGE}}) — files,
   lines, parsed vs unparsed, window, levels, **the problem to look at first**.
2. **Inventory table**, one row per input file:

   | Archivo | Formato | Líneas | Analizadas | Ventana (UTC) | Errores |
   |---|---|---|---|---|---|
   | api-2026-10-08.log.gz | JSON lines | 1 284 301 | 1 284 019 | 2026-10-08T00:00Z → 23:59Z | 9 412 ERROR |
   | access.txt | access log (conf. 97 %) | 402 118 | 401 902 | 2026-10-08T00:01Z → 23:59Z | 1 204 5xx |
   | notas.md | — | — | — | — | Omitido (no es un log) |

3. **Top signatures** — top 20 by count, then the tail as one aggregate row,
   since a 900-row table is not triage; `errors.csv` has all of them:

   | # | Nivel | Firma | Eventos | Primero | Último | Ejemplo |
   |---|---|---|---|---|---|---|
   | 1 | ERROR | Connection reset by peer upstream=<IP>:<NUM> | 8 214 | 00:03Z | 23:58Z | api-2026-10-08.log.gz:14 |
   | 2 | FATAL | OOMKilled container=<STR> limit=<NUM>Mi | 37 | 11:42Z | 11:49Z | api-2026-10-08.log.gz:881204 |
   | — | — | Resto (312 firmas distintas) | 4 118 | — | — | ver errors.csv |

4. **One `##` per top problem** — the verbatim (redacted) example line, when it
   started, whether it is **still happening at the end of the window**, the
   files it appears in, and what it suggests, labelled a **hypothesis** and not
   a diagnosis since you have the logs and not the system. Quoted lines keep
   their language — a translated log line is not evidence.
5. **`## Línea de tiempo`** — the shape of the volume (flat, spike, ramp, step
   change) and the **peak bucket with its count**; the rest is `timeline.csv`.
6. **`## Hallazgos de seguridad`** — redacted secrets by kind with file and
   line, auth failures over time, scanning patterns (`/.env`, `/wp-login.php`).
7. **`## Lagunas`** — unparsed lines with examples, missing or offset-less
   timestamps, clock skew, gaps, unreadable files, anything you only sampled;
   where there was none of a kind, say so.
8. **`## Reglas de normalización`** — the substitutions you ran, token by token,
   plus the continuation rule, so a reader can challenge every count above.
9. **`## Herramientas utilizadas`** — one line per tool with the version you ran
   (`python3 -V`, `uv --version`), what it was for, and any install that failed.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and checking your own
arithmetic: parsed + unparsed = lines read per file; `errors.csv`'s `count` sums
to the summary's error total; `timeline.csv` sums to the per-level totals; all
{{INPUT_COUNT}} input file(s) in the inventory. Say which does not close and by
how much — a stated discrepancy is a finding, a hidden one makes every other
number in the report doubtful.
