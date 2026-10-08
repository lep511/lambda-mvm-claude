# Claude Code as an autonomous agent in a MicroVM

Drop files in `input/`, run one script, get the agent's work back in
`output/<run-id>/`. The work is done by Claude Code running headless inside an
ephemeral Lambda MicroVM, with `--dangerously-skip-permissions` so it can use
its own tools — Bash, Read, Write — unattended.

**The image does not know what the job is.** It is Claude Code plus a toolbox;
the task lives in [`agent-prompt.md`](agent-prompt.md), which is uploaded with
every run. Rewrite that file and the same image does something else — no
rebuild, no code change.

`agent-prompt.md` is the **active** task. [`prompts/`](prompts) is the library
it was promoted from:

| | Produces | Needs |
| --- | --- | --- |
| [`prompts/xls-analysis.md`](prompts/xls-analysis.md) — spreadsheet analysis. | `ANALYSIS.md` + one CSV per sheet under `csv/` | `xlsx2csv`, `openpyxl`, `xlrd` — installed by the agent, per run |
| [`prompts/summary-docs.md`](prompts/summary-docs.md) — PDF summarisation. The task the lab shipped with. | one cross-referenced `SUMMARY.md` | `pdftotext`, `pdfinfo` — in the image (apt) |
| [`prompts/csv-to-dynamodb.md`](prompts/csv-to-dynamodb.md) — loads each CSV into a single-table DynamoDB design. **Currently active.** | rows in `sales-table`, plus `LOAD-REPORT.md` and `rejected/*.csv` | `boto3` — installed by the agent; **and** a `dynamodb:BatchWriteItem` grant, which `grant-permissions.sh` does not add |

Run any of them without promoting it — `./run-agent.sh --prompt
prompts/summary-docs.md` — or make one the default by copying it over
`agent-prompt.md`. Switching never needs a rebuild. (If you would rather not
keep a copy of the active task at the lab root, point `PROMPT_FILE` at a library
file instead; it means the same thing to both scripts.)

**The image ships no Python libraries at all.** The agent reads its task, works
out what it needs and installs it with [`uv`](https://docs.astral.sh/uv/) inside
the VM — so the "Needs" column above is a property of the *prompt*, not of the
image. See [the agent installs its own
libraries](#the-agent-installs-its-own-libraries).

## What makes this different from module-2.1

`module-2.1-claude-code/` also runs Claude Code in a MicroVM, but it pastes the
whole git diff *into the prompt* — so Claude answers in one shot and never
calls a tool. Here the agent is given a **directory** and has to work it out
itself: run `pdftotext`, read the output, decide what matters, write a file.
That is what requires `--dangerously-skip-permissions`, and that flag is what
makes the non-root user below necessary.

What this lab borrows from that one is its telemetry: the same in-VM OTel
collector, SigV4-forwarding Claude Code's spans to CloudWatch. It matters more
here, because "what did it actually do" has a longer answer when the agent
chose its own tools ([`TELEMETRY.md`](TELEMETRY.md)).

## Order of operations

```bash
./grant-permissions.sh            # once per account: S3 + TerminateMicrovm for the exec role
agent/build-image.sh              # builds the MicroVM image (~90-120s)
agent/test-image.sh               # smoke test — spends no Bedrock tokens

cp /path/to/*.xlsx input/         # whatever the active task expects
./run-agent.sh                    # launch → run → wait → output/<run-id>/
```

There is no Lambda, no stack and no orchestrator: `run-agent.sh` launches the
MicroVM itself and the agent shuts it down when it is finished.

`input/` ships empty on purpose. Nothing else needs editing — in the workshop's
code editor the required variables are already in `.bashrc`. Anywhere else, or
to override a knob, copy `.env.example` to `.env` and export it into the
terminal first: `set -a; source .env; set +a`
([why](#loading-env-into-your-terminal)).

A run id is a timestamp, and the whole job takes 2-10 minutes depending on how
much input there is. The last line of a successful run is where the result
landed, so it can be opened or copied from wherever the script was invoked. A
task that produced exactly one file names it; one that produced several names
the directory:

```
Result saved to:
  /home/ec2-user/lambda-mvm-workshop/claude-agent/output/20261007-230145/SUMMARY.md

Results saved to:
  /home/ec2-user/lambda-mvm-workshop/claude-agent/output/20261008-002347/
```

Subdirectories under `input/` are fine: paths are kept relative, so
`input/a/x.pdf` and `input/b/x.pdf` are two different documents rather than one
overwriting the other.

## The contract between the runtime and the task

Three things, and they are all the coupling there is:

| | |
| --- | --- |
| `input/` | everything under the job's S3 input prefix is downloaded into it |
| `output/` | everything the agent leaves in it is uploaded and handed back |
| `agent-prompt.md` | the task, rendered into the workspace as `CLAUDE.md` |

The agent's workspace inside the VM looks like this:

```
/workspace/runs/<run-id>/
├── CLAUDE.md      ← agent-prompt.md with its placeholders filled in
├── input/         ← downloaded from S3
├── extracted/     ← scratch space both tasks make; never uploaded
└── output/        ← uploaded to S3, verbatim, whatever is in it
```

`claude -p` is handed a short bootstrap that only states that contract — "read
./CLAUDE.md, your input is in ./input/, write what you want to keep into
./output/". Nothing in `app.py` mentions PDFs, summaries or `SUMMARY.md`: one
task writes a single markdown file, another writes a report plus three CSVs,
and the runtime treats both the same.

`_status.json` is the one name you cannot use for an artifact — it is the
completion signal `run-agent.sh` polls for, and a file with that name in
`output/` is reported as skipped rather than uploaded.

### Placeholders

`agent-prompt.md` is a template. The runtime substitutes:

| Placeholder | Becomes |
| --- | --- |
| `{{INPUT_DIR}}` / `{{OUTPUT_DIR}}` | `input` / `output` |
| `{{INPUT_COUNT}}` | how many files were downloaded |
| `{{INPUT_LIST}}` | a markdown bullet list of them |
| `{{RUN_ID}}` | the run id |
| `{{LANGUAGE}}` | `AGENT_LANGUAGE` or `--var LANGUAGE=`, with `es`/`en`/`pt`/`fr`/`de`/`it`/`source` expanded to a full name |
| `{{ANYTHING}}` | whatever you passed as `--var ANYTHING=...` |

The file counts come from the runtime, not the caller, so a prompt cannot be
told it was handed a different number of files than it was. A placeholder with
no value is left as-is and logged as a warning — which is how a typo surfaces.

### The agent installs its own libraries

The image is Claude Code, `python3`, `uv`, and the few command-line tools that
need root to install (`pdftotext`/`pdfinfo` from poppler, `git`, `aws`). What it
does **not** carry is a single third-party Python library. The agent decides:

```bash
uvx xlsx2csv -a input/ventas.xlsx extracted/ventas/   # a CLI tool, one-off
uv run --with openpyxl python inspect.py              # a script + its libraries
uv venv .venv && uv pip install openpyxl 'xlrd>=2.0'  # one env for the whole job
```

This is the "the image does not know what the job is" rule applied to
dependencies. Baking in `xlsx2csv`, `openpyxl` and `xlrd` would put three
libraries in the image for one task — dead weight whenever the other one is
active — and a task that wanted `pandas` would mean a rebuild. With the prompt
naming what it needs and the agent installing it, a new task is a new *file*
even when it needs a new library.

Four details make it work, and each one is a way it could break:

- **Outbound network.** `build-image.sh` launches the VM with the
  `INTERNET_EGRESS` network connector, which is what lets `uv` reach PyPI at run
  time. Remove it and every task fails on its first install, not just the ones
  reading spreadsheets.
- **The agent is not root** (see [below](#why-the-agent-runs-as-a-non-root-user)),
  so `uv pip install --system` — which writes to `/usr/local/lib` — fails. Every
  prompt says so; the working routes are `uvx`, `uv run --with`, and a venv in
  the job workspace. The cache lands in `$HOME/.cache/uv`, which `app.py` points
  at `/home/agent`, and dies with the VM.
- **`python3` is deliberately bare.** `app.py` needs `boto3` to upload artifacts
  and terminate the VM, and that one library lives in a venv at
  `/opt/agent-runtime` which is off `PATH` and named only by the Dockerfile's
  `CMD`. Installing it system-wide would have left `import boto3` quietly
  working for the agent too — a dependency nobody declared, until the day it
  moved.
- **`UV_PYTHON_DOWNLOADS=never`**, so `uv` uses the 3.12 already in the image
  rather than spending 30 seconds of a run's budget fetching its own.

`agent/test-image.sh` asserts both that `uv` is present and that it *runs as the
`agent` user* — a binary installed into root's home would otherwise surface as a
task failing to import something, minutes and tokens into a run.

The cost is a few seconds per install (cached within a run) and one more
external dependency in the path of a job. The rule for `requirements.txt` is now
narrow: it holds what `app.py` imports, nothing else.

### Making it do something else

Add a file to `prompts/` and point `--prompt` at it:

```bash
cat > prompts/to-english.md <<'EOF'
# Translation job

Translate every file in `{{INPUT_DIR}}/` into English. Extract PDFs with
`pdftotext -layout` first. Write one file per input into `{{OUTPUT_DIR}}/`,
named after the original with a `.en.md` extension. Preserve headings and
tables; do not summarise.
EOF

./run-agent.sh --prompt prompts/to-english.md
```

Same image, same script, different job — and that one needs no new tooling at
all, because `pdftotext` is already in the image. Nor would a task needing
`pandas` or `pypdf`: name the library in the prompt, tell the agent to install
it with `uv`, and the image never changes. What *does* need a rebuild:

| Change | Rebuild? |
| --- | --- |
| The task (`agent-prompt.md`, or a new file via `--prompt`) | no — it is job input |
| A placeholder value (`--var`, `AGENT_LANGUAGE`) | no |
| A new Python library for the agent to use | no — name it in the prompt, the agent installs it with `uv` |
| A new system tool in the toolbox (`tesseract-ocr` for OCR, an npm package) | yes — `agent/Dockerfile`, because apt needs root |
| A library `app.py` itself imports | yes — `agent/requirements.txt` |
| Tracing on/off, or what spans carry (`AGENT_TRACING`, `OTEL_*`) | yes — but the IAM grant and Transaction Search behind it are account settings, no rebuild ([`TELEMETRY.md`](TELEMETRY.md)) |
| Model, timeout, retries, memory | yes — baked env vars |
| The runtime itself (`agent/app.py`) | yes |

`agent/build-image.sh` is re-runnable: the first run creates the image, every
later one calls `update-microvm-image`, which adds a version (the first rebuild
yields `2.0`, not `1.1` — do not assume the scheme).
The version is assigned by the service, not chosen — the script persists what
it built as `AGENT_IMAGE_VERSION` in `/etc/profile.d/claude-agent-image.sh`,
and `run-agent.sh` and `test-image.sh` prefer it over anything else.

**Do not set `IMAGE_VERSION` anywhere**, and especially not in `.env`. That file
is sourced with `set -a`, so the value gets exported and stays in your shell;
every later run pins itself to the old version and silently executes stale
code — the job succeeds, it just runs the previous image. The old version stays
`SUCCESSFUL` forever, so nothing errors. Both scripts print the version they
resolved and a `NOTE:` when they ignore a stale pin, which is how you catch it.
To pin on purpose, use the variable they actually read:
`AGENT_IMAGE_VERSION=2.0 ./run-agent.sh`.

## Script options

Both scripts take `--help`.

`./run-agent.sh`

| Flag | What it does |
| --- | --- |
| *(none)* | Upload `agent-prompt.md` + `input/`, launch, run, download the artifacts. |
| `--prompt FILE` | Use a different task definition for this run. |
| `--var KEY=VALUE` | Fill `{{KEY}}` in the prompt. Repeatable. |
| `--rerun <run-id>` | Re-run over an earlier run's input without re-uploading it. The **current** prompt is still uploaded, so this is the one-liner for "same input, different task". Artifacts land under a fresh run id, leaving the old one intact. |
| `--fetch <run-id>` | Download a finished run's artifacts again. Launches nothing. This is the recovery path when the wait times out. |
| `--keep` | Do not reap the MicroVM if the job fails. Only affects the failure path — a successful run's VM terminates itself regardless. |

`agent/test-image.sh`

| Flag | What it does |
| --- | --- |
| *(none)* | Boot, `/health`, lifecycle hook, and the `/run` request contract. Spends no Bedrock tokens. |
| `--full` | Also runs the real task over `../input/`, which **does** spend tokens. The only check that exercises the prompt download, Bedrock, the S3 round trip and self-termination end to end, so it needs at least one file in `input/`. |
| `--keep` | Leave the VM running to poke at. Withholds `microvm_id`, so the agent will not shut itself down; the `idlePolicy` still reaps it. |

## How a run flows

```
agent-prompt.md + input/*
  └─ run-agent.sh
     ├─ aws s3 cp ──────────► s3://<artifacts>/claude-agent/runs/<run_id>/{agent-prompt.md,input/}
     ├─ RunMicrovm (HTTP_INGRESS + INTERNET_EGRESS, exec role, idlePolicy)
     ├─ poll until RUNNING
     ├─ CreateMicrovmAuthToken (port 9000)
     ├─ POST /run {input_uri, output_uri, prompt_uri, vars, microvm_id}  ← 202 at once
     │     └─ MicroVM, on a background thread
     │        ├─ downloads the input from S3
     │        ├─ downloads agent-prompt.md, renders it → the workspace CLAUDE.md
     │        ├─ claude -p --dangerously-skip-permissions   (as user `agent`)
     │        ├─ uploads everything in output/, then _status.json
     │        └─ TerminateMicrovm on ITSELF
     ├─ poll _status.json, download the artifacts
     └─ verify the VM is gone
```

Three things in that diagram are load-bearing:

- **`microvm_id` in the payload** is how the agent knows what to terminate. A
  VM has no way to ask what it is, so it has to be told.
- **The artifacts and `_status.json` go up before the VM terminates itself.**
  `_status.json` is the only completion signal `run-agent.sh` has; written
  after the shutdown call, it would die with the sender. The agent writes it on
  the failure path too, so a failed job reports a failure instead of looking
  like a slow one.
- **`idlePolicy` is the backstop, not the mechanism.** It catches a VM that
  crashed before reaching its own shutdown call. Its window has to outlast a
  whole run, because the agent receives no inbound request while it works.

`prompt_uri` is optional in the payload: without it the agent falls back to the
copy of `agent-prompt.md` baked into the image, which is what lets the smoke
test and a hand-rolled `run-microvm` work with no S3 staging. `_status.json`
reports which one ran as `prompt_source`.

## Why the agent runs as a non-root user

Claude Code refuses `--dangerously-skip-permissions` when it is running as
root outside a sandbox it recognises. The check amounts to:

```js
if (getuid() === 0 && IS_SANDBOX !== "1" && !CLAUDE_CODE_BUBBLEWRAP)
  → "cannot be used with root/sudo privileges" → exit(1)
```

This image is built from a Dockerfile but **runs as a MicroVM**, so none of the
container markers it looks for are there. Rather than setting a bypass
variable, the Dockerfile creates an `agent` user and `app.py` launches the CLI
with `subprocess.run(..., user="agent", group="agent")`. With `getuid() != 0`
the gate never fires, and the flag ends up used the way it is meant to be: an
unprivileged process inside an isolated, single-use VM.

The knock-on effect is credentials. The execution role's credentials may be
delivered through a path the `agent` user cannot read, so `app.py` resolves
them with `get_frozen_credentials()` and passes them as
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` — every AWS SDK
puts env vars first in its provider chain, so this works regardless of how the
VM delivers them.

The other knock-on effect is dependencies: an unprivileged agent cannot
`apt-get install` anything, nor write to the system `site-packages`. That is the
split described [above](#the-agent-installs-its-own-libraries) — apt packages
baked into the image, Python libraries installed per run into space the `agent`
user owns.

`agent/test-image.sh` asserts on this directly: `/health` reports
`claude_version_as_agent` and `uv_version_as_agent`, and a version string in
each means the root gate cannot fire and the agent can install what it needs.
Both cost no Bedrock tokens, so run it before the first real job.

## IAM

Two sides, both verified against the account rather than assumed.

**Your shell** launches the VM, so it needs `lambda:RunMicrovm`,
`GetMicrovm`, `CreateMicrovmAuthToken`, `PassNetworkConnector` and
`iam:PassRole` for the execution role. `WSParticipantRole` has
`AdministratorAccess`, so all of these are already allowed.

**The MicroVM** runs as `Module2ReviewerBuildRole-workshop`, which must be the
one passed: it is the only workshop role with `bedrock:InvokeModel*`, and
pointing this at `LambdaMicroVMExecutionRole-workshop` means a 403 from Bedrock
partway through a run. Out of the box that role has only `s3:GetObject` on the
artifacts bucket, so `grant-permissions.sh` adds what this lab needs, scoped to
`claude-agent/*` where it can be:

| Grant | Why |
| --- | --- |
| `s3:ListBucket` | the agent is handed a prefix, not a key list |
| `s3:PutObject` | the artifacts are the only thing that leaves the VM |
| `lambda:TerminateMicrovm` | nothing else is watching, so the agent stops itself |
| `xray:PutTraceSegments`, `xray:PutTelemetryRecords` | the in-VM collector signs spans as this role ([`TELEMETRY.md`](TELEMETRY.md)) |
| `logs:*` on `/aws/claude-agent/*` (4 actions) | the same collector writes the cost metrics and the event stream through CloudWatch Logs |

Skip that script and the symptoms are specific: no `ListBucket` gives "no input
files found", no `PutObject` means the work happens and cannot be delivered,
no `TerminateMicrovm` leaves the VM idling until the `idlePolicy` window
expires, and no `xray:*` or `logs:*` leaves runs succeeding with a `403` from the
collector and no telemetry. `run-agent.sh` checks the termination grant explicitly after every
run rather than assuming it worked.

## Knobs

`.env.example` is the full list, with the script that reads each one — and
[loading it into your terminal](#loading-env-into-your-terminal) is a step of
its own, because no script reads the file. The ones worth knowing about:

**Launch-time**, so no rebuild: `PROMPT_FILE` (default `agent-prompt.md`, the
same thing `--prompt` sets — always relative to `claude-agent/`, including when
`agent/build-image.sh` reads it, so one value works for both scripts),
`AGENT_LANGUAGE` (default `es`, the same thing
`--var LANGUAGE=` sets), `MVM_MAX_IDLE_SECONDS` (default `1800`, straight into
`run-microvm`'s `idlePolicy`) and `POLL_ATTEMPTS` (default `150`, i.e. 25 min
of watching for a result).

**Baked into the image** — `agent/build-image.sh` passes these via
`--environment-variables`, so changing one means re-running that script.

| Variable | Default | Notes |
| --- | --- | --- |
| `ANTHROPIC_MODEL` | `us.anthropic.claude-opus-5` | Any Claude inference profile in the account; `AmazonBedrockFullAccess` is attached, so IAM does not restrict the choice. `us.anthropic.claude-sonnet-4-6` is the cheaper option. |
| `CLAUDE_TIMEOUT` | `1500` | Seconds for one `claude -p` run. Kept under the credentials' lifetime. A timeout is terminal and not retried. |
| `CLAUDE_MAX_ATTEMPTS` | `3` | Retries on a non-zero exit from the CLI (transient Bedrock errors). |
| `MVM_MEMORY_MIB` | `2048` | What modules 2, 2.1 and 3 run on (module 4's tenant app uses 1024). Raise to `4096` if the agent dies mid-run on a large input set. |
| `AGENT_TRACING` | `1` | Claude Code telemetry to CloudWatch — traces, cost/token metrics and events. Sets both telemetry switches together; `0` builds an untraced image and `app.py` then skips the collector. [`TELEMETRY.md`](TELEMETRY.md). |
| `AGENT_TRACING_DETAILED` | `0` | Adds the beta detailed spans: each request's new context, system prompt preview and model output. Opt-in because it takes over delivery of logs and traces and multiplies volume. |

### Loading `.env` into your terminal

**The scripts read the ambient environment; none of them parses `.env`.** That
is deliberate — several values reference `$AWS_ACCOUNTID`, which only a shell
expands, and every other lab in this workshop works the same way — but it means
a `.env` you edited has no effect until you export it into the shell you run
the scripts from. The symptom otherwise is a hard failure naming the missing
variable, or worse, a run that quietly uses the default you meant to override.

One file, two lines:

```bash
cp .env.example .env          # once, then edit it
set -a; source .env; set +a   # export everything in it into this shell
```

`set -a` turns every assignment that follows into an export and `set +a` turns
that back off. Both halves matter: without `set -a` you get shell variables that
`./run-agent.sh` — a child process — never sees, and without `set +a` every
variable you happen to assign later in that terminal is exported too. Check it
landed before blaming a script:

```bash
echo "${AWS_REGION} | ${AWS_ACCOUNTID} | ${ARTIFACTS_BUCKET}"
```

It lasts as long as that terminal: a new tab, a reconnected code editor or a
fresh SSH session starts clean and needs the two lines again. Append them to
`~/.bashrc` (or `~/.zshrc`, the default shell on macOS) if you would rather not
think about it. In the workshop's code editor the required variables are in
`.bashrc` already, which is why `.env` is usually only for overriding a knob.

Two things that bite:

- **Exports persist; removing a line from `.env` does not unset anything.**
  Changing a value and re-sourcing works, but *deleting* a line leaves the old
  value exported for the life of that shell. `unset VAR`, or open a new
  terminal. This is exactly the `IMAGE_VERSION` trap described above: once
  exported, it pins every later run in that shell to a stale image.
- **The file is sourced, not parsed**, so it is bash: `${AWS_ACCOUNTID}`
  expands, `#` starts a comment, and a stray space around `=` or an unquoted
  value containing spaces fails loudly on the `source` line instead of being
  quietly skipped the way a dotenv parser would skip it.

A shell other than bash or zsh is worth one note: `set -a` is POSIX
(`allexport`), so the two lines work as-is in dash, ksh and zsh, but `fish`
has neither `set -a` nor `source`-of-bash-syntax — run `bash` first and work
from there, which is also what the scripts themselves need.

## What the two tasks tell the agent

Both specify an output shape and, more importantly, the rules that keep the
result honest. They are worth reading before writing a third one.

**`prompts/summary-docs.md`** — inventory table, one section per document, a
cross-document synthesis. Two rules carry more weight than the shape:

- Extract with `pdftotext -layout`, one document at a time, into `extracted/`
  — scratch space in the workspace root, so it is not mistaken for an artifact.
- A PDF that yields no text is a scan, and there is no OCR in this VM. Say so
  for that file instead of inferring content from its name — and this is the one
  gap the agent cannot close for itself, which the prompt tells it: the engine
  is an apt package and it is not root.

Adding OCR is one apt package (`tesseract-ocr`) in the Dockerfile if you ever
need it — a toolbox change, so it needs a rebuild. A Python library would not.

**`prompts/xls-analysis.md`** — the same discipline applied to numbers, which
is where an LLM is weakest:

- Compute every figure with a script and never by reading rows. A number you
  eyeballed from a CSV dump is a number you invented.
- Report data-quality problems instead of quietly fixing them — blank cells,
  duplicate rows, two spellings of one category, numbers stored as text — each
  named by sheet and cell.
- Install the reader you need: `uvx xlsx2csv` for the flat dump, `openpyxl` for
  structure and cell types, and `xlrd` for the legacy binary `.xls` that
  `openpyxl` cannot open at all. Each is named with what it is for, and the
  report has to end with the list of what was actually installed — which is also
  how you find out whether the agent agreed with the prompt's choice.

The payoff is specific: given a spreadsheet with `'12500'` stored as text, it
reported that the column total is 158 250 or 170 750 depending on whether the
string is coerced, and named the cell.

## Logs and traces

There is one log group, because there is one moving part:

```bash
aws logs tail /aws/lambda-microvms/mvm-claude-agent --since 30m --follow
```

Everything the agent does lands there — which prompt it resolved, the input
list, each `claude` attempt, the uploads, and the self-termination. A
`_status.json` that never appears is explained in that group.

One line in there is harmless and worth recognising:

```
HTTP 127.0.0.1 TLS handshake on plaintext port 9000 (151 bytes); answered 400 and closed
```

Port 9000 serves plain HTTP — the MicroVM proxy is what terminates TLS and
forwards, which is why `run-agent.sh` can call `https://<endpoint>` — so a
client aimed straight at the port (a browser tab, a `curl https://…:9000`, a
scanner) gets a 400 and nothing else. The bytes never parse into a request, so
no handler runs and no job state is touched. `app.py` collapses the whole
handshake to that one line rather than letting `http.server` escape a
ClientHello into the log group byte by byte. Note the address: the proxy
delivers every call locally, so `127.0.0.1` does not mean the caller was.

Logs tell you what the runtime did. What the *agent* did comes from the three
signals Claude Code emits, which an OTel collector in the VM SigV4-signs into
CloudWatch:

| Signal | Answers | Lands in |
| --- | --- | --- |
| Traces | what it did, step by step — one span per interaction, Bedrock call and tool execution, with the command, its output and the prompt attached | `aws/spans` |
| Metrics | what it cost — `claude_code.cost.usage` in USD, tokens by type, active time, lines of code | CloudWatch Metrics, `ClaudeCodeAgent` |
| Events | what happened in order — `user_prompt`, `assistant_response`, `tool_result`, `api_error`, … | `/aws/claude-agent/events` |

Everything carries `agent.run_id`, the same string as `output/<run-id>/`, so the
three join to each other and to the artifacts. A run is also **one trace**, not
one per turn: `app.py` mints a trace context, passes it to the agent as
`TRACEPARENT` — which `claude -p` honours — and publishes the `claude_agent.run`
root span itself, so the whole job appears as a single waterfall. The
`trace_id` ends up in `_status.json`. And all three signals are drained before
the VM terminates, so a run cannot outrun its own telemetry.

It needs two one-time account steps (IAM grants and Transaction Search) and a
rebuild to change. **[`TELEMETRY.md`](TELEMETRY.md)** covers enabling it, the
queries per signal, what ends up in a span, and the failure mode where every run
succeeds and nothing to look at ever appears.

If `run-agent.sh` times out, the run is not lost: the agent is still working
and still owns its VM. Re-fetch the result with `./run-agent.sh --fetch
<run-id>`.

## Inspecting and cleaning up

A run is silent while it works — `app.py` logs the start of `claude` and then
nothing until the agent exits — so "is it stuck or is it thinking?" has its own
command:

```bash
agent/status.sh                  # the run still in flight
agent/status.sh 20261008-122452  # a specific run, finished or not
```

It reports the MicroVM's state, the run's log timeline, **how long is left
before `CLAUDE_TIMEOUT` kills the attempt**, **what it has cost in dollars so
far**, what has reached S3, and — from the spans
([`TELEMETRY.md`](TELEMETRY.md)) — what the agent is doing right now: turns
taken, tool mix, tokens, which input files it has touched and which it has not,
and its last command. With no id it picks the newest run without a
`_status.json` *when a VM is actually alive*; otherwise it shows the most recent
run and names any run that died before writing its status file. It is
read-only: it launches nothing and terminates nothing.

```
==> run in flight: 20261008-122452 (newest without _status.json)
    vm         microvm-6a32cbdc-…  state=RUNNING  image=4.0  up=18m
==> clock
    claude     running for 17m (since 12:25:44 UTC)
    deadline   12:50:44 UTC — 7m 4s left (CLAUDE_TIMEOUT=1500s)
==> agent activity (spans)
    turns      48 LLM round trip(s), 48 tool call(s)
    files      7/10 touched  pending: Order_Details.xlsx, Products.xlsx, employee_tables.xlsx
==> cost
    spend      $2.8097 USD so far
    tokens     2379413 (all types; the span figures above are per-request)
```

The rest is plain AWS CLI:

```bash
# what runs exist, and what each one produced
aws s3 ls s3://lambda-mvm-workshop-artifacts-$AWS_ACCOUNTID/claude-agent/runs/ --recursive

# any MicroVM still alive (there should be none between runs)
aws lambda-microvms list-microvms --query 'items[].[microvmId,state,startedAt]' --output table

# stop a stray one by hand
aws lambda-microvms terminate-microvm --microvm-identifier <id>
```

A stray VM means self-termination failed; `run-agent.sh` says so at the end of
a run and terminates it for you, and the usual cause is
`grant-permissions.sh` not having been run. Old runs under `claude-agent/runs/`
are just S3 objects — delete the prefix whenever you like, nothing reads it
after the artifacts are downloaded.
