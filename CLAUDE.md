# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-contained project that runs Claude Code headless (`claude -p --dangerously-skip-permissions`)
as an autonomous agent inside an ephemeral AWS Lambda MicroVM. Files go in
`input/`, the agent's artifacts come back in `output/<run-id>/`. There is no
Lambda function, no CloudFormation stack and no orchestrator — `run-agent.sh`
launches the MicroVM directly and the agent terminates its own VM when done.

`README.md` is unusually complete; read it for the full narrative. This file
covers what is load-bearing when changing the code.

## Commands

```bash
./create-roles.sh           # once per account: artifacts bucket + the build and execution roles
./create-roles.sh --delete  # remove both roles (the bucket is left alone)
agent/build-image.sh        # build/update the MicroVM image (~90-120s)
AGENT_TRACING=0 agent/build-image.sh   # same, with Claude Code tracing off
agent/test-image.sh         # smoke test: contract checks only, spends no Bedrock tokens
agent/test-image.sh --full  # also runs the real task over ../input/ — DOES spend tokens
./run-agent.sh              # upload input/ + agent-prompt.md, launch, wait, download

./run-agent.sh --prompt prompts/xls-analysis.md   # different task, same image
./run-agent.sh --var LANGUAGE=en                  # fill a {{PLACEHOLDER}}
./run-agent.sh --rerun <run-id>                   # reuse an earlier run's input, current prompt
./run-agent.sh --fetch <run-id>                   # re-download a finished run (recovery path)

agent/status.sh                                   # what the in-flight run is doing (read-only)
agent/status.sh <run-id>                          # same for a specific run, finished or not

aws logs tail /aws/lambda-microvms/mvm-claude-agent --since 30m --follow
aws xray get-trace-segment-destination   # must be CloudWatchLogs/ACTIVE for spans
```

There is no linter, formatter or unit-test suite. `agent/test-image.sh` is the
only test harness and it runs against a live MicroVM; it has no way to select a
single check, so the granularity is "contract only" vs `--full`. Every script
takes `--help`.

Required environment, all from `.env`: `AWS_REGION` and `AWS_ACCOUNTID` are
hard-guarded; `ARTIFACTS_BUCKET`, `MVM_BUILD_ROLE_ARN` and
`MVM_EXECUTION_ROLE_ARN` have defaults derived from the account, and those
defaults are exactly what `create-roles.sh` creates — which is why a clean
clone needs nothing but the account id.
`.env.example` documents every optional knob and which script reads it. No
script parses `.env` — the values have to be in the ambient environment, so a
`.env` is activated with `set -a; source .env; set +a` (the README's "Loading
`.env` into your terminal" covers it). Keep it that way:
values like `ARTIFACTS_BUCKET` reference `$AWS_ACCOUNTID`, which only a shell
expands, and a dotenv parser would hand the scripts the literal string.

## Architecture

Three moving parts and one contract.

- **`agent/app.py`** — a task-agnostic runtime. A single-threaded-per-request
  `http.server` on port 9000: `POST /run` validates and returns 202 at once,
  then a background thread does the job. `GET /health` is the smoke test's main
  probe; every other path returns 200 because MicroVM lifecycle hooks land
  there. **Nothing in this file may mention a specific task** — no PDFs, no
  `SUMMARY.md`, no filenames. That is the whole design: one task writes a single
  markdown file, another writes a report plus N CSVs, and the runtime treats
  both identically.
- **`agent-prompt.md`** — the active task, uploaded per run and rendered into the
  VM workspace as `CLAUDE.md`, which is what the inner Claude Code reads as
  project context. (So "CLAUDE.md" means two different files in this repo:
  *this* one, for developing the project, and the generated one inside the VM.)
  `prompts/` is the library it is promoted from.
- **`run-agent.sh`** — stages to S3, `run-microvm`, polls for `RUNNING`, mints an
  auth token, `POST /run`, then polls S3 for `_status.json`.
- **`agent/status.sh`** — read-only observer for a run in flight. It derives
  "still running" the same way `run-agent.sh` does (no `_status.json` yet) and
  reads progress from the spans, so it needs no cooperation from the VM; keep
  it that way, since its whole point is being safe to run against a live job.
  Everything it reads from the log group is first narrowed to the run — the
  group belongs to the image, so two runs an hour apart are both in the window
  and an unscoped read puts another run's `claude attempt` in this run's
  countdown. It also names the task (from the staged prompt, because
  `prompt_source` says `agent-prompt.md` whichever prompt it was) and reports
  the telemetry verdict, including the one account setting behind it.
- **`agent/otel-collector.yaml`** — an `otelcol-contrib` beside the agent that
  SigV4-signs **all three** of Claude Code's signals into CloudWatch, because
  the CLI's own exporter cannot sign: traces to the X-Ray OTLP endpoint,
  metrics as EMF (cost in USD, tokens by type), events to a log group. Started
  lazily per job — the signer needs a region and the two AWS exporters need the
  run id for their log stream names, and both arrive on the payload — and
  drained before the VM terminates itself. `./TELEMETRY.md` is the
  operator-facing half of this.

The coupling between runtime and task is only: `input/` (downloaded from the
job's prefix), `output/` (uploaded verbatim), and `{{PLACEHOLDER}}`
substitutions. Caller-supplied `vars` are applied *before* the runtime's own
facts in `render_prompt`, so a job cannot talk the agent into believing it got a
different number of files than it did.

### Ordering invariants

These are not stylistic; breaking one produces a silent failure:

1. **Artifacts upload → `_status.json` → `flush_telemetry()` → `TerminateMicrovm`
   on self.** `_status.json` is the *only* completion signal `run-agent.sh` has.
   Written after the shutdown call it dies with the sender; not written on the
   failure path, a failed job is indistinguishable from a slow one and the
   poller just waits out its timeout. The telemetry flush sits between the two
   because traces, metrics and events still queued in the in-VM collector die
   with the VM and nothing retries them — and *after* the status file because
   the only thing a human waits for must not be delayed by telemetry
   bookkeeping. `run_job_and_finish` does all three in a `finally`.
2. **The run's trace context is minted before the collector can receive
   anything, and its root span is published before the flush.** `run_job`
   creates it first so `TRACEPARENT` can reach the agent — in `claude -p`
   sessions Claude Code parents its interaction spans under an inbound
   `TRACEPARENT`, which is the only reason a run is one trace instead of fifty.
   `close_run_span` then has to run before `flush_telemetry`, or the root ships
   after the drain and dies with the VM.
3. **`microvm_id` comes in on the payload.** A VM cannot ask what it is, so it
   has to be told what to terminate. Its absence is a degraded outcome (the
   `idlePolicy` reaps the VM later), never a reason to refuse work.
4. **`idlePolicy` is the backstop, not the mechanism.** Its window must outlast
   a whole run — the agent receives no inbound request while working, so a short
   window reaps a healthy VM mid-job.
5. **`_status.json` is a reserved name** in `output/`; `upload_artifacts` skips
   it and records it as skipped rather than letting a task race its own status.

### Why the agent runs as a non-root user

Claude Code refuses `--dangerously-skip-permissions` when `getuid() === 0`
outside a sandbox it recognises, and a MicroVM built from a Dockerfile presents
none of the container markers it looks for. Rather than setting a bypass
variable, the Dockerfile creates an `agent` user and `app.py` spawns the CLI with
`subprocess.run(..., user="agent", group="agent")`. `app.py` itself stays root —
it binds :9000 and needs setuid to drop privileges — and chowns each job
workspace to `agent`.

The knock-on effect is credentials: the execution role's may arrive via a path
the `agent` user cannot read, so `agent_env()` resolves them with
`get_frozen_credentials()` and passes `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` explicitly, dropping the
URI/file-based credential vars only when concrete ones replaced them.
`/health`'s `claude_version_as_agent` field asserts the gate cannot fire, and
costs no tokens.

The other knock-on effect is dependencies — see below.

### The agent installs its own Python libraries

The image carries **no third-party Python library** for the agent. It carries
`uv`, and each task names what it needs in its prompt; the agent installs it
inside the VM, per run (`uvx <tool>`, `uv run --with <lib>`, or a `uv venv` in
the workspace). This is the task-agnostic rule applied to dependencies: a task
that wants `pandas` is a prompt change, not an image change.

What holds it up, and what breaks it:

- `app.py`'s own `boto3` is installed into a venv at **`/opt/agent-runtime`**,
  off `PATH`, and the Dockerfile's `CMD` names that interpreter. Put
  `python3 app.py` back and the VM boots, fails to import `boto3`, and no job
  ever completes. The point of the venv is that the agent's `python3` stays
  bare, so no task can depend on something it did not install.
- `requirements.txt` is now **only** what `app.py` imports. Anything the agent
  would import belongs in a prompt.
- Run-time installs need the **`INTERNET_EGRESS` network connector**
  (`build-image.sh`, `--egress-network-connectors`). Without it every task fails
  on its first install, where before only the spreadsheet ones would have.
- `UV_PYTHON_DOWNLOADS=never` keeps `uv` on the image's 3.12 instead of fetching
  a managed interpreter mid-run.
- `AGENT_BOOTSTRAP` states the floor ("no libraries, not root, use uv") because
  it is a fact about the image, true for every task — a prompt that forgets to
  say it still gets an agent that knows.
- `/health`'s `uv_version_as_agent` is the one assertion that matters here: not
  that `uv` exists, but that it runs **as `agent`**.

## Operational gotchas

- **Never set `IMAGE_VERSION`, especially not in `.env`.** That file is meant to
  be sourced with `set -a`, so the value is exported for the life of the shell
  and pins every later run to a stale image version — which succeeds, just
  running old code. Both scripts prefer `AGENT_IMAGE_VERSION` (persisted by
  `build-image.sh` to `/etc/profile.d/claude-agent-image.sh`) and print a
  `NOTE:` when they ignore a stale pin. To pin deliberately, use
  `AGENT_IMAGE_VERSION=2.0 ./run-agent.sh`.
- **Image versions are assigned by the service, not chosen**, and the first
  rebuild yields `2.0`, not `1.1`. An update leaves the previous version
  `SUCCESSFUL` forever.
- **Two roles, split by phase, and the split is the service's.** Build-time
  hooks (`/ready`, `/validate`) execute under `--build-role-arn`; runtime hooks
  (`/run`, `/resume`, `/suspend`, `/terminate`) under `--execution-role-arn`.
  Everything `app.py` does happens inside `/run`, so Bedrock, S3,
  `TerminateMicrovm` and the telemetry exports all belong to the **execution**
  role and nothing but the source zip and build logs to the build role. Passing
  a role without `bedrock:InvokeModel*` as the execution role yields a 403
  partway through a run — the build succeeds regardless, which is what makes it
  confusing.
- **`PROMPT_FILE` is always relative to the project root**, including when
  `agent/build-image.sh` reads it (that script `cd`s to `agent/` but resolves the
  path against `..`). One variable, one meaning across both scripts.
- **ARM64 only.** The Dockerfile pulls the `aarch64` AWS CLI; Lambda MicroVMs run
  on Graviton.
- Skipping `create-roles.sh` gives specific symptoms, one per grant: no
  `ListBucket` → "no input files found"; no `PutObject` → work done, nothing
  delivered; no `TerminateMicrovm` → VM idles until the policy window expires;
  no `bedrock:InvokeModel*` → 403 partway through; no `xray:*` → runs succeed
  and the collector logs `Exporting failed ... 403` for traces; no `logs:*` on
  `/aws/claude-agent/*` → the same, for cost metrics and events; no `logs:*` on
  `/aws/lambda-microvms/*` → artifacts arrive but the VM's own stdout never
  does, so `status.sh` is blind and there is no `telemetry drained` line to
  read. That last one is easy to miss when migrating off a role that carried
  `CloudWatchLogsFullAccess`.
- **Telemetry fails silently by construction.** Four independent things have to
  be true — the image built with `AGENT_TRACING=1`, the role holding the xray
  actions, the role holding the CloudWatch Logs actions, and Transaction Search
  `ACTIVE` in that region — and none of them is on the path of a successful
  run. The symptom is always the same: artifacts delivered, nothing to look at.
  `app.py` logs `telemetry drained: spans N/N, metrics N/N, logs N/N` right
  before it terminates the VM, which is the cheapest place to look and says
  which signal is missing; `./TELEMETRY.md` has the ordered checklist.
- **Content gates are not one switch.** Prompts, assistant text, tool inputs
  and tool output each have their own `OTEL_LOG_*` variable, and Claude Code's
  own `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` — not the OTel SDK limits — is what
  actually truncates content. Setting only the SDK limits, as this image did
  once, changes nothing.

## What needs a rebuild

| Change | Rebuild? |
| --- | --- |
| The task (`agent-prompt.md`, a new file under `prompts/`) | no — it is job input |
| A placeholder value (`--var`, `AGENT_LANGUAGE`) | no |
| A Python library the **agent** uses | no — name it in the prompt, it installs it with `uv` |
| A Python library **`app.py`** imports (`agent/requirements.txt`) | yes |
| A system tool (`agent/Dockerfile`, e.g. `tesseract-ocr` for OCR) | yes — apt needs root |
| Model, timeout, retries, memory (baked env vars in `build-image.sh`) | yes |
| Telemetry on/off (`AGENT_TRACING`), detailed spans (`AGENT_TRACING_DETAILED`), what the signals carry (`OTEL_*`), `agent/otel-collector.yaml` | yes |
| The IAM grants and Transaction Search behind telemetry | no — account settings |
| `agent/app.py` | yes |

The tools that are in the image stay there whether or not the active task uses
them — that, plus the agent installing its own libraries, is what makes
switching tasks rebuild-free. If you add a tool, also add it to `TOOLS` in
`app.py` so `/health` and the smoke test report it.

## Conventions in this codebase

The code is commented densely and in prose, and the comments explain *why* a
thing is the way it is — usually naming the failure it prevents. Match that:
a change here without a note on what breaks without it will read as noise next
to its neighbours. Bash is `set -euo pipefail`, `cd "$(dirname "$0")"` first, JSON
built with `jq -n` rather than string interpolation, and user-facing errors print
the next command to run.
