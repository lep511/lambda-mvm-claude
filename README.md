# claude-agent — Claude Code as an autonomous agent in a MicroVM

Drop files in `input/`, run one script, get the agent's work back in
`output/<run-id>/`. The work is done by Claude Code running headless inside an
ephemeral Lambda MicroVM, with `--dangerously-skip-permissions` so it can use
its own tools — Bash, Read, Write — unattended.

**The image does not know what the job is.** It is Claude Code plus a toolbox;
the task lives in [`agent-prompt.md`](agent-prompt.md), which is uploaded with
every run. Rewrite that file and the same image does something else — no
rebuild, no code change.

`agent-prompt.md` is the **active** task. [`prompts/`](prompts) is the library
it was promoted from, and both entries are real tasks this lab has run:

| | Produces | Needs |
| --- | --- | --- |
| [`prompts/xls-analysis.md`](prompts/xls-analysis.md) — spreadsheet analysis. **Currently active.** | `ANALYSIS.md` + one CSV per sheet under `csv/` | `xlsx2csv`, `openpyxl`, `xlrd` |
| [`prompts/summary-docs.md`](prompts/summary-docs.md) — PDF summarisation. The task the lab shipped with. | one cross-referenced `SUMMARY.md` | `pdftotext`, `pdfinfo` |

Run either without promoting it — `./run-agent.sh --prompt
prompts/summary-docs.md` — or make one the default by copying it over
`agent-prompt.md`. Both toolchains live in the image permanently, so switching
never needs a rebuild. (If you would rather not keep a copy of the active task
at the lab root, point `PROMPT_FILE` at a library file instead; it means the
same thing to both scripts.)

## What makes this different from module-2.1

`module-2.1-claude-code/` also runs Claude Code in a MicroVM, but it pastes the
whole git diff *into the prompt* — so Claude answers in one shot and never
calls a tool. Here the agent is given a **directory** and has to work it out
itself: run `pdftotext`, read the output, decide what matters, write a file.
That is what requires `--dangerously-skip-permissions`, and that flag is what
makes the non-root user below necessary.

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
code editor the required variables are already in `.bashrc`.

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
all, because `pdftotext` is already in the image. What *does* need a rebuild:

| Change | Rebuild? |
| --- | --- |
| The task (`agent-prompt.md`, or a new file via `--prompt`) | no — it is job input |
| A placeholder value (`--var`, `AGENT_LANGUAGE`) | no |
| A new Python library for the agent to use | yes — `agent/requirements.txt` |
| A new system tool in the toolbox (`tesseract-ocr` for OCR, an npm package) | yes — `agent/Dockerfile` |
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

`agent/test-image.sh` asserts on this directly: `/health` reports
`claude_version_as_agent`, and a version string there means the gate cannot
fire. It costs no Bedrock tokens, so run it before the first real job.

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
artifacts bucket, so `grant-permissions.sh` adds the three things this lab
needs, scoped to `claude-agent/*` where it can be:

| Grant | Why |
| --- | --- |
| `s3:ListBucket` | the agent is handed a prefix, not a key list |
| `s3:PutObject` | the artifacts are the only thing that leaves the VM |
| `lambda:TerminateMicrovm` | nothing else is watching, so the agent stops itself |

Skip that script and the symptoms are specific: no `ListBucket` gives "no input
files found", no `PutObject` means the work happens and cannot be delivered,
and no `TerminateMicrovm` leaves the VM idling until the `idlePolicy` window
expires. `run-agent.sh` checks the last one explicitly after every run rather
than assuming it worked.

## Knobs

`.env.example` is the full list, with the script that reads each one. The ones
worth knowing about:

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

## What the two tasks tell the agent

Both specify an output shape and, more importantly, the rules that keep the
result honest. They are worth reading before writing a third one.

**`prompts/summary-docs.md`** — inventory table, one section per document, a
cross-document synthesis. Two rules carry more weight than the shape:

- Extract with `pdftotext -layout`, one document at a time, into `extracted/`
  — scratch space in the workspace root, so it is not mistaken for an artifact.
- A PDF that yields no text is a scan, and there is no OCR in this VM. Say so
  for that file instead of inferring content from its name.

Adding OCR is one apt package (`tesseract-ocr`) in the Dockerfile if you ever
need it — a toolbox change, so it needs a rebuild.

**`prompts/xls-analysis.md`** — the same discipline applied to numbers, which
is where an LLM is weakest:

- Compute every figure with `python3` and never by reading rows. A number you
  eyeballed from a CSV dump is a number you invented.
- Report data-quality problems instead of quietly fixing them — blank cells,
  duplicate rows, two spellings of one category, numbers stored as text — each
  named by sheet and cell.
- `xlsx2csv` for the flat dump, `openpyxl` for structure and cell types, and
  `xlrd` for the legacy binary `.xls` that `openpyxl` cannot open at all.

The payoff is specific: given a spreadsheet with `'12500'` stored as text, it
reported that the column total is 158 250 or 170 750 depending on whether the
string is coerced, and named the cell.

## Logs

There is one log group, because there is one moving part:

```bash
aws logs tail /aws/lambda-microvms/mvm-claude-agent --since 30m --follow
```

Everything the agent does lands there — which prompt it resolved, the input
list, each `claude` attempt, the uploads, and the self-termination. A
`_status.json` that never appears is explained in that group.

If `run-agent.sh` times out, the run is not lost: the agent is still working
and still owns its VM. Re-fetch the result with `./run-agent.sh --fetch
<run-id>`.

## Inspecting and cleaning up

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
