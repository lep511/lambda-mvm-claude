"""claude-agent — Claude Code as an autonomous agent inside a Lambda MicroVM.

This file is a task-agnostic runtime. **What the agent does is not in here**:
it is in `agent-prompt.md`, which run-agent.sh uploads with every job and this
process renders into the job workspace as CLAUDE.md — the idiomatic way to
steer Claude Code without inflating the -p prompt. Rewrite that file and the
same image does a different job.

The three things this runtime knows, and the only coupling it has to any task:

  input/   everything under the job's `input_uri` is downloaded into it
  output/  everything the agent leaves in it is uploaded to `output_uri`
  vars     {{PLACEHOLDER}} substitutions for the prompt

Single HTTP server on port 9000. Path-based routing:
  POST /run        — accepts a job
  GET  /health     — health check (also the smoke test's main probe)
  ANY  /aws/...    — MicroVM lifecycle hooks (returns 200 OK)
  everything else  — 200 OK (treated as a hook)

The MicroVM lifecycle model this file supports:

  1. Lambda POSTs /aws/lambda-microvms/runtime/v1/run  → 200
  2. run-agent.sh POSTs /run                           → 202 (immediate)
  3. Background thread downloads the input, resolves and renders the prompt,
     and runs `claude -p` as the unprivileged `agent` user (minutes)
  4. Background thread uploads output/, then _status.json
  5. Background thread waits for the OTel collector to ship the run's
     telemetry (traces, cost/token metrics, events)
  6. Background thread calls TerminateMicrovm on ITSELF

The order of 4, 5 and 6 is not cosmetic. _status.json is the only completion
signal run-agent.sh gets, so it has to be in S3 before this VM stops existing.
Spans still queued in the collector die with the VM and nothing retries them,
so they are drained before the terminate call — and after the status file, so
the thing a human is waiting for is never delayed by telemetry. The
`idlePolicy` the VM was launched with is the backstop for a crash that never
reaches step 6 at all.

Why the agent runs as a non-root user: Claude Code refuses
--dangerously-skip-permissions when getuid() == 0 outside a recognised
sandbox, and a MicroVM is not one of the things it recognises. Dropping
privileges for the child sidesteps the gate by not tripping it. See the
Dockerfile for the full note.
"""

import json
import logging
import mimetypes
import os
import pwd
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time
import traceback
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse

import boto3

logging.basicConfig(
    level=logging.INFO,
    format='{"timestamp":"%(asctime)s","level":"%(levelname)s","message":"%(message)s"}',
)
logger = logging.getLogger(__name__)

PORT = 9000

AGENT_USER = "agent"
AGENT_GROUP = "agent"
AGENT_HOME = "/home/agent"

RUNS_ROOT = "/workspace/runs"

# Fallback task, baked in by the Dockerfile at image-build time. The per-run
# upload wins; this is what keeps the image self-sufficient (and the smoke test
# meaningful) when no prompt_uri is passed.
BAKED_PROMPT = "/workspace/agent-prompt.md"

# The workspace contract every task shares. The -p bootstrap below states both
# names, and a prompt refers to them through {{INPUT_DIR}} / {{OUTPUT_DIR}}
# rather than hardcoding them, so they are changeable in exactly one place.
INPUT_DIR = "input"
OUTPUT_DIR = "output"

# Reserved key: publish_status writes it, and it is the completion signal
# run-agent.sh polls for. A task that happened to leave a file with this name
# in output/ would race its own status — so it is never uploaded from disk.
STATUS_KEY = "_status.json"

# Per-artifact ceiling. "Whatever the agent left in output/" is unbounded by
# design, and a runaway file would be discovered on the invoice rather than
# here. Skipped files are named in _status.json, not silently dropped.
MAX_ARTIFACT_BYTES = 64 * 1024 * 1024

# run_id becomes a path component both locally and in S3, so it is constrained
# rather than trusted: a value containing '..' would escape RUNS_ROOT.
RUN_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")

# Placeholder syntax for the prompt template: {{UPPER_SNAKE}}.
PLACEHOLDER_RE = re.compile(r"\{\{([A-Z0-9_]+)\}\}")

DEFAULT_MODEL = "us.anthropic.claude-opus-5"

# Tools the image ships with, reported by /health. These are the ones the agent
# cannot provide for itself: apt packages (poppler, for prompts/summary-docs.md)
# need root, and uv is how every Python library gets into a run — a task whose
# libraries it cannot install is a task that cannot start, which makes `uv` the
# one entry here that every prompt now depends on. Python libraries are NOT
# listed, because the image ships none: the prompt decides, and the agent
# installs. Reporting the list is what lets the smoke test rule out a missing
# tool before a job burns minutes discovering it.
TOOLS = (
    "uv",
    "uvx",
    "python3",
    "pdftotext",
    "pdfinfo",
    "git",
    "aws",
    # Not a tool the agent calls — app.py runs it alongside the agent to ship
    # Claude Code's spans. Reported here because its absence is invisible
    # otherwise: runs keep succeeding and no trace ever appears.
    "otelcol-contrib",
)

# Seconds to wait after the last log line before calling TerminateMicrovm on
# ourselves, so CloudWatch has a chance to ship it. Without this the most
# interesting line — why a run failed — is the one most likely to be lost.
LOG_FLUSH_SECONDS = 3

# Credential env vars that point at a URI or file the unprivileged child may
# not be able to reach. Dropped ONLY when concrete frozen credentials have been
# injected in their place — otherwise the child would be left with nothing.
SCOPED_CREDENTIAL_VARS = (
    "AWS_WEB_IDENTITY_TOKEN_FILE",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN",
    "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
    "AWS_PROFILE",
)

# Convenience for the {{LANGUAGE}} placeholder: a prompt can ask for a language
# by code instead of spelling the name out. Anything not listed is passed
# through verbatim, so "Catalan" or "ja" work without being enumerated here.
LANGUAGE_NAMES = {
    "es": "Spanish (español)",
    "en": "English",
    "pt": "Portuguese (português)",
    "fr": "French (français)",
    "de": "German (Deutsch)",
    "it": "Italian (italiano)",
    # Escape hatch: let the agent decide from the input itself.
    "source": "the predominant language of the source documents",
}


def model_id() -> str:
    return os.environ.get("ANTHROPIC_MODEL", DEFAULT_MODEL)


def language_name(code: str | None = None) -> str:
    """Resolve {{LANGUAGE}}: per-run `vars` first, then the image's default."""
    raw = (code or os.environ.get("AGENT_LANGUAGE") or "es").strip()
    return LANGUAGE_NAMES.get(raw.lower(), raw)


# ── Health probes ─────────────────────────────────────────────────────────────


def bedrock_enabled() -> bool:
    """Claude Code reaches Bedrock with the execution role's credentials, so
    there is no API key to check — only that the switch was baked in."""
    return os.environ.get("CLAUDE_CODE_USE_BEDROCK") == "1"


def agent_user_exists() -> bool:
    try:
        pwd.getpwnam(AGENT_USER)
        return True
    except KeyError:
        return False


_versions_lock = threading.Lock()
_versions: dict[str, str] = {}


def version_as_agent(argv: list[str], timeout: int = 60) -> str:
    """Run `<tool> --version` as the unprivileged agent user.

    Reports the version string, or an `error:`/`exit N` marker — never raises,
    because /health has to answer even when the thing it is probing is broken.
    `shutil.which` in TOOLS says a binary exists for root; this says it RUNS as
    the user that will actually invoke it — a different claim, and the one that
    catches a tool installed somewhere only root can reach.

    Cached per command: each call spawns a process, and /health gets polled.
    """
    key = " ".join(argv)
    with _versions_lock:
        if key in _versions:
            return _versions[key]
        try:
            proc = subprocess.run(
                argv,
                cwd="/tmp",
                user=AGENT_USER,
                group=AGENT_GROUP,
                env={
                    "HOME": AGENT_HOME,
                    "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
                    "USER": AGENT_USER,
                },
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            result = (
                (proc.stdout or proc.stderr or "").strip() or f"exit {proc.returncode}"
            )
        except Exception as e:
            result = f"error: {e}"
        _versions[key] = result
        return result


def claude_version_as_agent() -> str:
    """The single most informative probe in this image: if the CLI starts as
    `agent`, then getuid() != 0 and the root gate on
    --dangerously-skip-permissions cannot fire — the failure an image can ship
    with and only reveal on the first real job. Costs no Bedrock tokens, so the
    smoke test can assert on it freely."""
    return version_as_agent(["claude", "--version"])


def uv_version_as_agent() -> str:
    """uv is the agent's only route to a Python library — the image ships none —
    so this answers the question the toolbox map cannot: can the user that does
    the installing actually run it? A binary present in /usr/local/bin but
    unusable as `agent` would otherwise surface as a task failing to import
    something, minutes and tokens into a run.

    A short timeout: `uv --version` is local and instant, and the first /health
    already pays for `claude --version` — together they have to stay inside the
    smoke test's request timeout."""
    return version_as_agent(["uv", "--version"], timeout=15)


# ── OpenTelemetry: in-VM collector that SigV4-forwards telemetry to CloudWatch ─
#
# Claude Code emits three signals over OTLP — spans (claude_code.interaction,
# .llm_request, .tool.execution, ...), metrics (cost in USD, tokens by type,
# session and active-time counters) and events (user_prompt, tool_result,
# api_request, ...) — but its exporter cannot SigV4-sign any of them, so a
# local otelcol-contrib signs and forwards all three: traces to the X-Ray OTLP
# endpoint, metrics as EMF, events to CloudWatch Logs. ../TELEMETRY.md picks
# the story up from there, and otel-collector.yaml is the wiring.
#
# This is the one part of the runtime that has to care about this VM shutting
# itself down. A span exported to a closed port is lost silently, and this
# process is the thing that closes the port — so the collector starts before
# `claude` and is drained before TerminateMicrovm.

COLLECTOR_BIN = "otelcol-contrib"
COLLECTOR_CONFIG = "/workspace/otel-collector.yaml"
COLLECTOR_OTLP_PORT = 4318
COLLECTOR_TELEMETRY_PORT = 8888

# The three signals Claude Code emits, and the collector counters that account
# for each one. Keyed by the suffix otelcol uses in its own metric names, which
# is also what reads well in a log line.
COLLECTOR_SIGNALS = {
    "spans": "spans",
    "metrics": "metric_points",
    "logs": "log_records",
}

# Items sitting in an exporter's sending queue. This is the cross-signal
# backstop for the flush: the awscloudwatchlogs exporter publishes no
# sent/failed counters until its first export attempt completes, so a flush
# that waited only for per-signal accounting would spin out its timeout on
# every run. Queue size exists from startup for every exporter that has a
# queue, and an exporter without one exports synchronously — nothing to drain.
COLLECTOR_QUEUE_METRIC = "otelcol_exporter_queue_size"

# How long to wait for the collector's listener before giving up on tracing
# this run. Measured, not guessed: cold in a fresh MicroVM, otelcol-contrib
# took 66s from exec to binding :4318 — it is a 379 MB static binary being
# demand-paged while the runtime downloads the job's input. The old 20s
# (set when the collector had the VM to itself) expired every
# time and the first half-minute of every trace was lost. Most of this is
# spent in parallel with the input download, so the usual visible cost is far
# smaller than the number suggests.
COLLECTOR_START_TIMEOUT = 120.0

_collector_lock = threading.Lock()
_collector_proc = None

# The current run's trace context and timings, set by run_job and consumed by
# run_job_and_finish when it publishes the root span. Module-level because one
# VM serves exactly one job — the same reason _collector_proc can be.
_run_trace: dict | None = None


def telemetry_config() -> dict:
    """The telemetry decisions this image was built with, as /health sees them.

    Reported because they are invisible from the outside and each one fails
    silently: an image whose metrics exporter is `none` produces runs that look
    identical to one that exports cost data, and a content gate that is off
    produces spans that look complete until you need the command that was run.
    The smoke test asserts on this, which is cheaper than discovering it from
    an empty CloudWatch namespace a week later.
    """
    return {
        "exporters": {
            "traces": os.environ.get("OTEL_TRACES_EXPORTER", "unset"),
            "metrics": os.environ.get("OTEL_METRICS_EXPORTER", "unset"),
            "logs": os.environ.get("OTEL_LOGS_EXPORTER", "unset"),
        },
        "content": {
            "user_prompts": os.environ.get("OTEL_LOG_USER_PROMPTS") == "1",
            "assistant_responses": os.environ.get("OTEL_LOG_ASSISTANT_RESPONSES") == "1",
            "tool_details": os.environ.get("OTEL_LOG_TOOL_DETAILS") == "1",
            "tool_content": os.environ.get("OTEL_LOG_TOOL_CONTENT") == "1",
            "max_length": os.environ.get("CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH", "unset"),
        },
        # The beta pair. Both or neither: with only the variable set Claude Code
        # produces no detailed spans, and with only the endpoint set it keeps
        # exporting normally — so reporting them together is the only way to
        # see that the image is in a coherent state.
        "detailed": {
            "enabled": os.environ.get("ENABLE_BETA_TRACING_DETAILED") == "1",
            "endpoint": os.environ.get("BETA_TRACING_ENDPOINT", ""),
        },
    }


def tracing_enabled() -> bool:
    """Both Claude Code switches must be on for any span to exist.

    Checked rather than assumed because build-image.sh can bake them off
    (AGENT_TRACING=0): with tracing off there is nothing for the collector to
    receive, and starting it would only add a process and a confusing log line.
    """
    return (
        os.environ.get("CLAUDE_CODE_ENABLE_TELEMETRY") == "1"
        and os.environ.get("CLAUDE_CODE_ENHANCED_TELEMETRY_BETA") == "1"
    )


def _wait_for_port(port: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as s:
            s.settimeout(0.5)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.25)
    return False


def start_collector(region: str, run_id: str = "") -> bool:
    """Launch otelcol-contrib, pinned to `region`. Returns True if it is running.

    Launch only — this does NOT wait for the listener; `wait_for_collector()`
    does, immediately before the agent starts. The split is the fix for a real
    failure: `otelcol-contrib` is a 379 MB static binary and this is its first
    exec in a fresh MicroVM, so every page faults in from the image's backing
    store while the runtime is also downloading the job's input. Measured cold,
    it took **66 seconds** to bind :4318. Blocking on it here would charge the
    job that entire wall-clock time; waiting later lets the warm-up overlap the
    input download, which is dead time for the collector anyway.

    Started lazily on the first job rather than at boot: the SigV4 signer, the
    xray endpoint and the CloudWatch log streams all need values this image
    deliberately does not bake in — the region (for the same reason AWS_REGION
    is not baked in) and the run id, which names the metrics and events streams
    so one run's telemetry is one stream. The job payload is where both first
    become known, and a VM serves exactly one job.

    A failure here is logged and otherwise ignored. Losing a trace is a
    degraded outcome; refusing to do the job over it would be a worse one.

    Collector stdout/stderr is inherited so its startup lines and its export
    failures land in /aws/lambda-microvms/<IMAGE_NAME> next to the runtime's
    own logs — which is where you read "Exporting failed" when a trace does
    not show up.
    """
    global _collector_proc
    if not tracing_enabled():
        logger.info("tracing disabled; not starting the collector")
        return False

    with _collector_lock:
        if _collector_proc is not None and _collector_proc.poll() is None:
            return True
        logger.info(f"starting {COLLECTOR_BIN} for region {region} (warming up)")
        try:
            _collector_proc = subprocess.Popen(
                [COLLECTOR_BIN, "--config", COLLECTOR_CONFIG],
                env={
                    **os.environ,
                    "MVM_TRACE_REGION": region,
                    # Names the metrics and events log streams. Never empty:
                    # the AWS exporters refuse a blank log_stream_name, which
                    # would take the collector down with it.
                    "MVM_RUN_ID": run_id or "unknown-run",
                    "AWS_REGION": region,
                    "AWS_DEFAULT_REGION": region,
                },
            )
        except Exception as e:
            logger.error(f"could not start {COLLECTOR_BIN} ({e!r}); spans will be lost")
            return False
    return True


def wait_for_collector(timeout: float = COLLECTOR_START_TIMEOUT) -> bool:
    """Block until the collector is listening. Call it right before `claude`.

    Claude Code's exporter posts to 127.0.0.1:4318 every two seconds and drops
    silently when nothing is listening, so every second the agent runs ahead of
    this is a second of spans thrown away — the session's opening spans, which
    are the ones that say what the task was.

    The budget is generous (see `COLLECTOR_START_TIMEOUT`) because the thing it
    waits for is a cold-start, not a hang: the only costs of waiting are
    seconds, and the cost of not waiting is a trace that starts mid-run. A
    timeout is still not fatal — the job proceeds untraced rather than failing.
    """
    if not tracing_enabled():
        return False
    if _collector_proc is None:
        return False

    started = time.monotonic()
    if not _wait_for_port(COLLECTOR_OTLP_PORT, timeout=timeout):
        # Distinguish "died" from "still not up": a collector that exited has
        # already explained itself in the lines above, a slow one has not.
        rc = _collector_proc.poll()
        reason = (
            f"it exited with {rc} — its own error is in the lines above"
            if rc is not None
            else f"still not listening after {timeout:.0f}s"
        )
        logger.error(
            f"collector did not open :{COLLECTOR_OTLP_PORT} ({reason}); "
            "this run's spans will be dropped"
        )
        return False
    logger.info(
        f"collector listening on 127.0.0.1:{COLLECTOR_OTLP_PORT} "
        f"after {time.monotonic() - started:.1f}s of waiting"
    )
    return True


def _prom_sum(body: str, name: str) -> int | None:
    """Sum every sample of a Prometheus counter, or None if it has none.

    Absence and zero are different answers here. otelcol publishes
    `..._sent_<signal>` only after that exporter's first export attempt
    completes, so "absent" means "no verdict yet" — reporting it as 0 would
    make the flush treat an unexported batch as accounted for.
    """
    pattern = re.compile(rf"^{name}(?:\{{[^}}]*\}})?\s+([0-9.e+-]+)", re.M)
    samples = [float(m.group(1)) for m in pattern.finditer(body)]
    return int(sum(samples)) if samples else None


def telemetry_counters() -> dict | None:
    """Per-signal accounting from the collector, or None if it is unreachable.

    Shape: {"spans": {"accepted": 143, "sent": 143, "failed": 0}, ..., "queued": 0}
    where a value of None means the collector has not published that counter.
    /health reports this verbatim, which makes "did my telemetry leave the VM"
    answerable without a single query against CloudWatch.
    """
    url = f"http://127.0.0.1:{COLLECTOR_TELEMETRY_PORT}/metrics"
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            body = r.read().decode("utf-8", "replace")
    except Exception:
        return None

    counters: dict = {}
    for signal, suffix in COLLECTOR_SIGNALS.items():
        counters[signal] = {
            "accepted": _prom_sum(body, f"otelcol_receiver_accepted_{suffix}"),
            "sent": _prom_sum(body, f"otelcol_exporter_sent_{suffix}"),
            "failed": _prom_sum(body, f"otelcol_exporter_send_failed_{suffix}"),
        }
    counters["queued"] = _prom_sum(body, COLLECTOR_QUEUE_METRIC) or 0
    return counters


def _signal_settled(stats: dict, queued: int, quiet: bool) -> bool:
    """Has this signal's telemetry left the collector?

    The precise answer is the per-signal counters adding up: sent + failed >=
    accepted. Some exporters publish no counters until their first export
    attempt completes, though, so there is a fallback — and the fallback needs
    BOTH an empty queue and `quiet`, meaning nothing new has been accepted for
    longer than the batch window.

    The `quiet` half is not belt-and-braces, it is the correctness condition.
    Data sits in the batch processor for up to its timeout before any exporter
    sees it, and an exporter with no sending queue reports no backlog while it
    waits — so "nothing queued" on its own is true a few milliseconds after a
    batch arrives, which is exactly when declaring the flush done would throw
    that batch away.
    """
    accepted = stats["accepted"] or 0
    if accepted == 0:
        return True
    if stats["sent"] is not None:
        return (stats["sent"] + (stats["failed"] or 0)) >= accepted
    return queued == 0 and quiet


def flush_telemetry(
    timeout: float = 25.0, grace: float = 5.0, settle: float = 4.0
) -> None:
    """Block until the collector has shipped the run's traces, metrics and logs.

    This MUST run before self_terminate(). Nothing outside this VM is waiting
    for the telemetry and nothing will retry it: whatever is still in the
    collector's queues when TerminateMicrovm lands dies with the VM — the job
    succeeds, delivers its artifacts, and its trace, its cost metrics and its
    event log never arrive.

    It runs AFTER _status.json for the opposite reason: the status file is the
    only thing a human is waiting on, so it must not be delayed by telemetry
    bookkeeping.

    `grace` is how long to keep waiting for the FIRST telemetry before
    concluding there is nothing to flush — a job that failed before `claude`
    ever started produces none at all and should not stall the shutdown.

    `settle` is how long the accepted counts must stop moving before an
    exporter that publishes no counters is taken at its word (see
    `_signal_settled`); it has to exceed the collector's batch timeout.
    """
    if not tracing_enabled():
        return

    start = time.monotonic()
    deadline = start + timeout
    last: dict | None = None
    accepted_seen = -1
    last_change = start
    while time.monotonic() < deadline:
        c = telemetry_counters()
        if c is None:
            logger.warning("collector telemetry endpoint unreachable; not flushing")
            return
        last = c
        queued = c["queued"]
        accepted_total = sum((c[s]["accepted"] or 0) for s in COLLECTOR_SIGNALS)
        if accepted_total != accepted_seen:
            accepted_seen = accepted_total
            last_change = time.monotonic()
        quiet = (time.monotonic() - last_change) >= settle

        if accepted_total == 0:
            if time.monotonic() - start >= grace:
                logger.info("no telemetry was produced; nothing to flush")
                return
        elif queued == 0 and all(
            _signal_settled(c[s], queued, quiet) for s in COLLECTOR_SIGNALS
        ):
            logger.info(f"telemetry drained: {_counters_summary(c)}")
            failed = sum((c[s]["failed"] or 0) for s in COLLECTOR_SIGNALS)
            if failed:
                logger.warning(
                    f"{failed} item(s) failed to export — check the collector's "
                    "'Exporting failed' lines above (usually IAM or Transaction Search)"
                )
            return
        time.sleep(1.0)

    # A timeout names what was still outstanding: with three signals, "it timed
    # out" on its own does not say which exporter to go and look at.
    logger.warning(
        f"telemetry flush timed out after {timeout}s; "
        f"{_counters_summary(last) if last else 'no counters'}"
    )


def _counters_summary(c: dict) -> str:
    parts = []
    for signal in COLLECTOR_SIGNALS:
        s = c[signal]
        sent = "?" if s["sent"] is None else s["sent"]
        parts.append(f"{signal} {sent}/{s['accepted'] or 0}")
    return ", ".join(parts) + f", queued {c['queued']}"


# ── S3 helpers ────────────────────────────────────────────────────────────────


def parse_s3_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc:
        raise ValueError(f"not an s3:// uri: {uri!r}")
    return parsed.netloc, parsed.path.lstrip("/")


def content_type_for(name: str) -> str:
    """Best-effort content type, so a summary opens as text rather than a
    download. Markdown and plain text get an explicit charset."""
    if name.endswith((".md", ".markdown")):
        return "text/markdown; charset=utf-8"
    if name.endswith(".txt"):
        return "text/plain; charset=utf-8"
    guessed, _ = mimetypes.guess_type(name)
    return guessed or "application/octet-stream"


def download_inputs(s3, uri: str, dest_dir: str) -> list[str]:
    """Pull every object under `uri` into `dest_dir`, returning the filenames.

    Listing the prefix needs s3:ListBucket on the bucket, condition-scoped to
    claude-agent/* — create-roles.sh is what grants it, and without it a job
    ends with "no input files found". boto3 is used rather than
    `aws s3 cp --recursive` so a permission failure surfaces as a named
    exception in this log group instead of a CLI exit code.

    Keys keep their path relative to the prefix rather than being flattened to
    a basename: run-agent.sh uploads the input directory recursively, so two
    files in different subdirectories can share a name, and flattening would
    silently drop one of them.
    """
    bucket, prefix = parse_s3_uri(uri)
    if prefix and not prefix.endswith("/"):
        prefix += "/"

    root = os.path.realpath(dest_dir)
    names = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            rel = key[len(prefix):] if key.startswith(prefix) else os.path.basename(key)
            if not rel or rel.endswith("/"):
                continue  # directory placeholder

            dest = os.path.join(dest_dir, rel)
            # An S3 key may legally contain '..'; keep the write inside dest_dir.
            if not os.path.realpath(dest).startswith(root + os.sep):
                logger.warning(f"skipping key outside the job directory: {key}")
                continue

            os.makedirs(os.path.dirname(dest), exist_ok=True)
            s3.download_file(bucket, key, dest)
            names.append(rel)
    return sorted(names)


def upload_text(s3, uri: str, body: str, content_type: str) -> None:
    bucket, key = parse_s3_uri(uri)
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType=content_type,
    )


def upload_artifacts(s3, out_dir: str, output_uri: str) -> tuple[list[dict], list[dict]]:
    """Upload everything the agent left in the workspace's output/.

    This is the whole output contract, and the reason the runtime needs to know
    no filenames: one task writes SUMMARY.md, the next writes a report plus
    three CSVs, and neither needs a code change. Subdirectories keep their
    structure. Returns (uploaded, skipped).
    """
    bucket, base_key = parse_s3_uri(output_uri)
    base_key = base_key.strip("/")

    uploaded: list[dict] = []
    skipped: list[dict] = []

    for root, _dirs, files in os.walk(out_dir):
        for name in sorted(files):
            path = os.path.join(root, name)
            rel = os.path.relpath(path, out_dir)

            if rel == STATUS_KEY:
                logger.warning(
                    f"not uploading {OUTPUT_DIR}/{rel}: that name is reserved for "
                    "the run's completion signal"
                )
                skipped.append({"key": rel, "reason": "reserved name"})
                continue
            # Follows no symlinks: an agent-made link would otherwise upload
            # whatever it points at, under a name that hides it.
            if os.path.islink(path) or not os.path.isfile(path):
                skipped.append({"key": rel, "reason": "not a regular file"})
                continue

            size = os.path.getsize(path)
            if size > MAX_ARTIFACT_BYTES:
                logger.warning(f"skipping {rel}: {size} bytes exceeds the artifact cap")
                skipped.append({"key": rel, "reason": f"larger than {MAX_ARTIFACT_BYTES} bytes", "bytes": size})
                continue

            key = f"{base_key}/{rel}" if base_key else rel
            s3.upload_file(
                path, bucket, key, ExtraArgs={"ContentType": content_type_for(name)}
            )
            uploaded.append({"key": rel, "uri": f"s3://{bucket}/{key}", "bytes": size})

    return uploaded, skipped


# ── Workspace preparation ─────────────────────────────────────────────────────


def load_prompt(s3, prompt_uri: str | None) -> tuple[str, str]:
    """Resolve the task definition. Returns (template, source).

    Per-run upload wins so that editing agent-prompt.md and re-running is the
    whole edit loop — no image rebuild. The baked copy is the fallback, which
    is also what makes a job with no prompt_uri (the smoke test) work.
    """
    if prompt_uri:
        try:
            bucket, key = parse_s3_uri(prompt_uri)
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
            if body.strip():
                return body, prompt_uri
            logger.warning(f"{prompt_uri} is empty; falling back to the baked prompt")
        except Exception as e:
            logger.warning(
                f"could not read {prompt_uri} ({e!r}); falling back to the baked prompt"
            )

    try:
        with open(BAKED_PROMPT, encoding="utf-8") as f:
            return f.read(), f"image:{BAKED_PROMPT}"
    except FileNotFoundError as e:
        raise RuntimeError(
            f"no task to run: {prompt_uri or '(no prompt_uri passed)'} was not "
            f"readable and {BAKED_PROMPT} is missing from the image"
        ) from e


def render_prompt(
    job_dir: str, template: str, input_names: list[str], run_id: str, variables: dict
) -> None:
    """Substitute the placeholders and write the job's CLAUDE.md.

    Caller-supplied `vars` are applied first and the runtime's own facts
    second, so a job cannot talk the agent into believing it was handed a
    different number of files than it was.
    """
    values = {str(k): str(v) for k, v in (variables or {}).items()}
    values["LANGUAGE"] = language_name(values.get("LANGUAGE"))
    values.update(
        {
            "RUN_ID": run_id,
            "INPUT_DIR": INPUT_DIR,
            "OUTPUT_DIR": OUTPUT_DIR,
            "INPUT_COUNT": str(len(input_names)),
            "INPUT_LIST": "\n".join(f"- `{n}`" for n in input_names)
            or "- (no files found)",
        }
    )

    rendered = template
    for key, value in values.items():
        rendered = rendered.replace("{{" + key + "}}", value)

    # A typo in a hand-written prompt would otherwise reach the agent as a
    # literal {{FOO}} and be silently ignored.
    leftover = sorted(set(PLACEHOLDER_RE.findall(rendered)))
    if leftover:
        logger.warning(f"unsubstituted placeholder(s) in the prompt: {leftover}")

    with open(os.path.join(job_dir, "CLAUDE.md"), "w", encoding="utf-8") as f:
        f.write(rendered)


def chown_tree(path: str) -> None:
    """Hand the whole job workspace to the agent user.

    The child runs as `agent`, so it needs to traverse, read and write here —
    including creating scratch directories and writing into output/.
    """
    entry = pwd.getpwnam(AGENT_USER)
    os.chown(path, entry.pw_uid, entry.pw_gid)
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            os.chown(os.path.join(root, name), entry.pw_uid, entry.pw_gid)


def otel_attr(value: str) -> str:
    """Make a string safe for OTEL_RESOURCE_ATTRIBUTES.

    That variable is a flat `k=v,k=v` list with no escaping, so a value
    containing ',' or '=' does not fail — it silently splits into attributes
    nobody can query. Whitespace goes too, for the same reason.
    """
    return re.sub(r"[\s,=]+", "_", value.strip()) or "unknown"


def otel_resource_attrs(run_id: str = "", prompt_source: str = "") -> dict:
    """Resource attributes for everything this run emits.

    One function because two things need the same answer and must not drift:
    the agent's `OTEL_RESOURCE_ATTRIBUTES`, and the resource on the run span
    this process publishes itself. If they disagreed, the run span and the
    agent's spans would land in the backend as two unrelated services.

    Nothing task-specific goes in: run id, task source and model are facts
    about the invocation, true of every job this image runs.
    """
    return {
        "service.name": otel_attr(os.environ.get("OTEL_SERVICE_NAME", "mvm-claude-agent")),
        "service.namespace": "lambda-mvm-claude",
        "deployment.environment.name": "claude-agent",
        "agent.run_id": otel_attr(run_id),
        "agent.task": otel_attr(prompt_source),
        "agent.model": otel_attr(model_id()),
    }


def new_trace_context() -> tuple[str, str, str]:
    """A W3C trace context for one run: (trace_id, span_id, traceparent).

    This is what turns a run from N unrelated traces into one. In `claude -p`
    sessions Claude Code reads TRACEPARENT from its own environment and parents
    each `claude_code.interaction` span under it, and it stamps the same ids on
    the event records — so passing this to the child joins the agent's spans,
    the agent's events and this process's own run span into a single trace.
    Interactive sessions ignore an inbound TRACEPARENT; `-p` is exactly the
    case this lab runs.

    Sampled flag is always 01: the collector is the sampler here, and a run too
    boring to trace is not a thing this lab produces.
    """
    trace_id = secrets.token_hex(16)
    span_id = secrets.token_hex(8)
    return trace_id, span_id, f"00-{trace_id}-{span_id}-01"


def publish_run_span(
    trace_id: str,
    span_id: str,
    start_ns: int,
    end_ns: int,
    attrs: dict,
    ok: bool,
) -> None:
    """POST the run's root span to the local collector, as OTLP/JSON.

    Without it the agent's spans reference a parent that never arrived and the
    trace has no root — the whole run shows up as a headless pile of
    interactions. With it, one trace is one run: duration, outcome and the
    agent's work nested underneath.

    OTLP/JSON over the collector's HTTP receiver on purpose: it needs no OTel
    SDK, so the runtime venv keeps its single dependency. Failures are logged
    and ignored, like every other telemetry failure in this file — a missing
    root span must never be the reason a delivered job reports failure.
    """
    if not tracing_enabled():
        return

    def kv(items: dict) -> list:
        out = []
        for k, v in items.items():
            if isinstance(v, bool):
                out.append({"key": k, "value": {"boolValue": v}})
            elif isinstance(v, int):
                out.append({"key": k, "value": {"intValue": str(v)}})
            else:
                out.append({"key": k, "value": {"stringValue": str(v)}})
        return out

    payload = {
        "resourceSpans": [
            {
                "resource": {"attributes": kv(attrs["resource"])},
                "scopeSpans": [
                    {
                        "scope": {"name": "claude-agent.runtime"},
                        "spans": [
                            {
                                "traceId": trace_id,
                                "spanId": span_id,
                                "name": "claude_agent.run",
                                "kind": 1,  # SPAN_KIND_INTERNAL
                                "startTimeUnixNano": str(start_ns),
                                "endTimeUnixNano": str(end_ns),
                                "attributes": kv(attrs["span"]),
                                # 1 = OK, 2 = ERROR
                                "status": {"code": 1 if ok else 2},
                            }
                        ],
                    }
                ],
            }
        ]
    }

    url = f"http://127.0.0.1:{COLLECTOR_OTLP_PORT}/v1/traces"
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            if r.status >= 300:
                logger.warning(f"run span rejected by the collector: HTTP {r.status}")
                return
        logger.info(f"run span published (trace {trace_id})")
    except Exception as e:
        logger.warning(f"could not publish the run span ({e!r}); the trace will have no root")


def agent_env(
    region: str,
    run_id: str = "",
    prompt_source: str = "",
    traceparent: str = "",
) -> dict:
    """Environment for the unprivileged child.

    Resolves concrete credentials and passes them as the three standard env
    vars. The execution role's credentials may be delivered through a path the
    `agent` user cannot read, and every AWS SDK puts env vars first in its
    provider chain, so freezing them here is what gets Bedrock working for a
    non-root child regardless of the delivery mechanism.

    It also stamps the run onto everything the child emits — the resource
    attributes that identify the run, and TRACEPARENT so the child's spans and
    events join this run's trace instead of starting their own. The OTEL_*
    wiring itself is baked into the image (see the Dockerfile); what can only
    be known here is WHICH run this is, which is what makes a trace in
    CloudWatch joinable to a directory in output/ and to a line in the log
    group.
    """
    env = dict(os.environ)

    frozen = None
    credentials = boto3.Session().get_credentials()
    if credentials is not None:
        frozen = credentials.get_frozen_credentials()

    if frozen and frozen.access_key and frozen.secret_key:
        for var in SCOPED_CREDENTIAL_VARS:
            env.pop(var, None)
        env["AWS_ACCESS_KEY_ID"] = frozen.access_key
        env["AWS_SECRET_ACCESS_KEY"] = frozen.secret_key
        if frozen.token:
            env["AWS_SESSION_TOKEN"] = frozen.token
        else:
            env.pop("AWS_SESSION_TOKEN", None)
    else:
        # Leave the inherited chain alone — it is all the child has.
        logger.error(
            "could not resolve credentials to pass to the agent; "
            "Bedrock calls will likely fail with a credentials error"
        )

    env.update(
        {
            "HOME": AGENT_HOME,
            "USER": AGENT_USER,
            "LOGNAME": AGENT_USER,
            "AWS_REGION": region,
            "AWS_DEFAULT_REGION": region,
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "ANTHROPIC_MODEL": model_id(),
            "OTEL_RESOURCE_ATTRIBUTES": ",".join(
                f"{k}={v}" for k, v in otel_resource_attrs(run_id, prompt_source).items()
            ),
        }
    )
    if traceparent:
        env["TRACEPARENT"] = traceparent
    return env


# ── Running the agent ─────────────────────────────────────────────────────────

# Deliberately says nothing about any particular task: it points at CLAUDE.md
# and states the workspace contract. Everything task-specific is in the prompt
# file, which is where it can be changed without touching this image.
#
# The dependency sentence belongs here rather than in a prompt for the same
# reason: "this machine has no Python libraries installed" is a fact about the
# image, true of every task, and a task that assumed otherwise would waste its
# first tool calls on an ImportError. Prompts repeat the specifics they rely on;
# this guarantees the floor even for one that forgets.
AGENT_BOOTSTRAP = (
    f"Read ./CLAUDE.md in this directory and carry out the job it describes, "
    f"start to finish. Your input files are in ./{INPUT_DIR}/. Write every file "
    f"you want to keep into ./{OUTPUT_DIR}/ — that directory is the only thing "
    f"that leaves this machine. No third-party Python libraries are installed "
    f"and you are not root, so install whatever you need yourself with uv: "
    f"`uv run --with <library> python script.py` for a script, `uvx <tool>` for "
    f"a command-line tool, or `uv venv` plus `uv pip install` in this directory "
    f"for something you will reuse. Do not use `--system`, and do not assume a "
    f"library is present — check or install it. Nobody is watching this "
    f"session, so do not stop to ask questions, and do not stop until the job "
    f"is complete."
)


def run_claude(job_dir: str, env: dict, timeout: int) -> tuple[str, str]:
    """Run `claude -p` as the agent user. Returns (stdout, last_error).

    Claude Code makes many Bedrock calls over an agentic run, and a transient
    4xx/5xx on any of them makes the CLI exit non-zero even though a retry
    usually succeeds — so the whole invocation is retried with exponential
    backoff. A timeout is terminal
    instead of retried: a second full-length attempt would risk outrunning the
    idlePolicy window the VM was launched with, and get the VM reaped from
    under the agent.
    """
    max_attempts = int(os.environ.get("CLAUDE_MAX_ATTEMPTS", "3"))
    last_error = ""

    for attempt in range(1, max_attempts + 1):
        logger.info(f"claude attempt {attempt}/{max_attempts} (model {model_id()})")
        try:
            proc = subprocess.run(
                [
                    "claude",
                    "-p",
                    "--dangerously-skip-permissions",
                    "--output-format",
                    "text",
                    AGENT_BOOTSTRAP,
                ],
                cwd=job_dir,
                user=AGENT_USER,
                group=AGENT_GROUP,
                env=env,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return "", f"claude timed out after {timeout}s"
        except PermissionError as e:
            # app.py must be root to drop privileges for the child.
            return "", f"cannot run as {AGENT_USER} (app.py is not privileged): {e}"

        if proc.returncode == 0:
            return proc.stdout or "", ""

        # `claude -p` often prints the failure to stdout rather than stderr,
        # so both are captured — stderr alone is empty on Bedrock client errors.
        last_error = (proc.stderr or proc.stdout or "").strip()[-800:] or "no output"
        logger.warning(
            f"claude attempt {attempt}/{max_attempts} failed "
            f"(exit {proc.returncode}): {last_error}"
        )
        if attempt < max_attempts:
            time.sleep(2**attempt)  # 2s, then 4s

    return "", f"claude failed after {max_attempts} attempts: {last_error}"


def run_job(body: dict) -> dict:
    """Download, run the task, upload. Returns a result dict (never raises)."""
    global _run_trace
    run_id = str(body["run_id"])
    input_uri = body["input_uri"]
    output_uri = body["output_uri"].rstrip("/")
    region = body["region"]

    # The run's trace context, created before anything that could emit a span.
    # Stashed in module state because run_job_and_finish publishes the root
    # span after this function has returned — a VM serves exactly one job, so
    # there is nothing to key it by.
    trace_id, span_id, traceparent = new_trace_context()
    _run_trace = {
        "trace_id": trace_id,
        "span_id": span_id,
        "start_ns": time.time_ns(),
        "run_id": run_id,
        "prompt_source": "",
    }

    started = time.monotonic()
    job_dir = os.path.join(RUNS_ROOT, run_id)
    in_dir = os.path.join(job_dir, INPUT_DIR)
    out_dir = os.path.join(job_dir, OUTPUT_DIR)

    try:
        shutil.rmtree(job_dir, ignore_errors=True)
        os.makedirs(in_dir, exist_ok=True)
        os.makedirs(out_dir, exist_ok=True)

        s3 = boto3.client("s3", region_name=region)

        # Launch the collector as early as possible and do NOT wait for it
        # here: it needs the better part of a minute to warm up cold, and the
        # input download below is exactly the dead time to spend on it. The
        # wait happens just before `claude`, which is the first thing that
        # emits a span. Region comes from the payload because the SigV4 signer
        # needs one.
        start_collector(region, run_id)

        logger.info(f"downloading input from {input_uri}")
        input_names = download_inputs(s3, input_uri, in_dir)
        if not input_names:
            return {
                "success": False,
                "run_id": run_id,
                "error": f"no input files found under {input_uri}",
            }
        logger.info(f"{len(input_names)} input file(s): {', '.join(input_names)}")

        template, prompt_source = load_prompt(s3, body.get("prompt_uri"))
        logger.info(f"task prompt from {prompt_source}")
        _run_trace["prompt_source"] = prompt_source
        render_prompt(job_dir, template, input_names, run_id, body.get("vars") or {})
        chown_tree(job_dir)

        # The last moment it is still free: from the next line on, every span
        # the agent emits with no listener on :4318 is gone for good.
        wait_for_collector()

        timeout = int(os.environ.get("CLAUDE_TIMEOUT", "1500"))
        stdout, error = run_claude(
            job_dir,
            agent_env(region, run_id, prompt_source, traceparent),
            timeout,
        )

        artifacts, skipped = upload_artifacts(s3, out_dir, output_uri)
        artifacts_source = f"{OUTPUT_DIR}/"

        # The agent is asked to leave its files in output/. If it answered
        # inline instead, keep that rather than throwing away a run that did
        # the work.
        if not artifacts and stdout.strip():
            fallback = "agent-stdout.md"
            body = stdout.strip()
            fallback_uri = f"{output_uri}/{fallback}"
            upload_text(s3, fallback_uri, body, "text/markdown; charset=utf-8")
            artifacts = [
                {
                    "key": fallback,
                    "uri": fallback_uri,
                    "bytes": len(body.encode("utf-8")),
                }
            ]
            artifacts_source = f"stdout (nothing was written to {OUTPUT_DIR}/)"
            logger.warning(f"no files in {OUTPUT_DIR}/; falling back to claude stdout")

        if not artifacts:
            return {
                "success": False,
                "run_id": run_id,
                "error": error or f"the agent produced no files in {OUTPUT_DIR}/",
                "prompt_source": prompt_source,
                "inputs": input_names,
                "input_count": len(input_names),
            }

        logger.info(
            f"uploaded {len(artifacts)} artifact(s) to {output_uri}: "
            f"{', '.join(a['key'] for a in artifacts)}"
        )

        result = {
            "success": True,
            "run_id": run_id,
            "inputs": input_names,
            "input_count": len(input_names),
            "artifacts": artifacts,
            "artifact_count": len(artifacts),
            "artifacts_source": artifacts_source,
            "prompt_source": prompt_source,
            "model": model_id(),
            "duration_s": round(time.monotonic() - started, 1),
            # The way back from a delivered artifact to the trace that produced
            # it, without having to guess at timestamps in the console.
            "trace_id": trace_id,
        }
        if skipped:
            result["artifacts_skipped"] = skipped
        if error:
            # Files were produced, so the run is delivered — but the CLI still
            # exited non-zero, and that belongs in the record.
            result["claude_error"] = error
            logger.warning(f"artifacts delivered despite a claude failure: {error}")
        return result

    except Exception as e:
        logger.error(f"run_job failed: {e!r}\n{traceback.format_exc()}")
        return {
            "success": False,
            "run_id": run_id,
            "error": f"{type(e).__name__}: {e}",
            "duration_s": round(time.monotonic() - started, 1),
        }
    finally:
        shutil.rmtree(job_dir, ignore_errors=True)


# ── Background runner: job, status file, self-termination ─────────────────────


def publish_status(body: dict, result: dict) -> None:
    """Write _status.json next to the artifacts.

    This is the ONLY completion signal run-agent.sh has, so two things matter.
    It must be written on the failure path too — otherwise a failed job looks
    identical to a slow one and the script just waits out its timeout. And it
    must be written before this VM terminates itself, or the signal dies with
    the sender.
    """
    try:
        s3 = boto3.client("s3", region_name=body["region"])
        status = dict(result)
        status["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        upload_text(
            s3,
            f"{body['output_uri'].rstrip('/')}/{STATUS_KEY}",
            json.dumps(status, indent=2),
            "application/json",
        )
        logger.info(f"wrote {STATUS_KEY}")
    except Exception as e:
        logger.error(f"could not write {STATUS_KEY}: {e!r}")


def self_terminate(body: dict) -> None:
    """Call TerminateMicrovm on this very MicroVM.

    The agent owns its own shutdown: there is no orchestrator watching, so
    without this the VM would sit idle until the idlePolicy window expired and
    the account would pay for the gap. The id is passed in by run-agent.sh
    because a VM has no way to ask what it is.

    Needs lambda:TerminateMicrovm on the execution role — that is one of the
    grants in create-roles.sh. Absence of the id, or a failure here, is
    not fatal: the idlePolicy still reaps the VM, just later.
    """
    microvm_id = body.get("microvm_id")
    if not microvm_id:
        logger.warning(
            "no microvm_id in the job payload; leaving shutdown to the idlePolicy"
        )
        return
    try:
        logger.info(f"work finished; terminating {microvm_id}")
        time.sleep(LOG_FLUSH_SECONDS)
        boto3.client("lambda-microvms", region_name=body["region"]).terminate_microvm(
            microvmIdentifier=microvm_id
        )
    except Exception as e:
        logger.error(
            f"self-termination failed ({e!r}); the idlePolicy will reap this VM"
        )


def run_job_and_finish(body: dict) -> None:
    """Run the task, publish the result, ship the trace, shut this VM down.

    The ordering is the contract: status to S3 first, then the telemetry
    flush, then terminate — and all three happen whether the job succeeded or
    not. Status leads because it is the only thing a human is waiting on; the
    flush sits between because telemetry still in the collector's queues dies
    with the VM, and nothing retries it.
    """
    result = {
        "success": False,
        "run_id": body.get("run_id"),
        "error": "runner did not complete",
    }
    try:
        result = run_job(body)
    except Exception as e:
        logger.error(f"runner threw: {e!r}\n{traceback.format_exc()}")
        result = {
            "success": False,
            "run_id": body.get("run_id"),
            "error": f"{type(e).__name__}: {e}",
        }
    finally:
        publish_status(body, result)
        # Root span before the flush, so the flush ships it with everything
        # else. After publish_status for the same reason the flush is: the
        # status file is what a human is waiting for.
        close_run_span(result)
        flush_telemetry()
        self_terminate(body)


def close_run_span(result: dict) -> None:
    """End the run's root span and hand it to the collector.

    Separate from publish_run_span so that function stays a dumb OTLP POST:
    this is where the run's outcome is turned into span attributes, and where a
    job that failed before run_job created a context is tolerated.
    """
    if not _run_trace:
        return
    run_id = _run_trace["run_id"]
    attrs = {
        "resource": otel_resource_attrs(run_id, _run_trace["prompt_source"]),
        "span": {
            "agent.run_id": run_id,
            "agent.task": _run_trace["prompt_source"] or "unknown",
            "agent.model": model_id(),
            "run.success": bool(result.get("success")),
            "run.input_count": int(result.get("input_count") or 0),
            "run.artifact_count": int(result.get("artifact_count") or 0),
        },
    }
    if result.get("error"):
        attrs["span"]["run.error"] = str(result["error"])[:400]
    publish_run_span(
        _run_trace["trace_id"],
        _run_trace["span_id"],
        _run_trace["start_ns"],
        time.time_ns(),
        attrs,
        bool(result.get("success")),
    )


# ── HTTP handler ──────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    # First two bytes of a TLS record: type 0x16 (handshake) and the legacy
    # major version 0x03. It is what a client speaking https:// to this
    # PLAINTEXT port sends, and http.server reads it as a request line.
    TLS_RECORD_PREFIX = b"\x16\x03"

    def log_message(self, fmt, *args):
        """Everything http.server wants to log, including what it could not
        parse — so this is where a TLS handshake stops being a wall of binary.

        Unfiltered, one `curl https://…:9000` or one browser tab aimed straight
        at the port writes an escaped ClientHello into the lab's ONLY log
        group, twice (http.server logs it from both log_error and
        log_request), and it reads like a crash. It is not one: the bytes never
        parse into a request, so nothing reached a handler, no job state was
        touched, and the server already answered 400 and closed the
        connection. Collapsing it to a single line keeps the group readable
        while still saying it happened — a port being probed is worth knowing.

        Normal calls never look like this: run-agent.sh and test-image.sh go
        through the MicroVM proxy, which terminates TLS and forwards plaintext
        (which is also why the client address is always 127.0.0.1 here, even
        for a caller that is not local).
        """
        raw = getattr(self, "raw_requestline", b"") or b""
        if raw.startswith(self.TLS_RECORD_PREFIX):
            # Once per connection, not once per log call: the flag is what
            # makes this independent of how many times http.server decides to
            # report the same unparseable line.
            if not getattr(self, "_tls_noise_logged", False):
                self._tls_noise_logged = True
                logger.info(
                    f"HTTP {self.address_string()} TLS handshake on plaintext "
                    f"port {PORT} ({len(raw)} bytes); answered 400 and closed"
                )
            return
        logger.info(f"HTTP {self.address_string()} {fmt % args}")

    def _json(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/health":
            self._json(
                200,
                {
                    "status": "healthy",
                    "bedrock_enabled": bedrock_enabled(),
                    "model": model_id(),
                    "default_language": language_name(),
                    # The baked fallback task. False means a job without a
                    # prompt_uri has nothing to run.
                    "prompt_baked": os.path.isfile(BAKED_PROMPT),
                    "tools": {t: shutil.which(t) is not None for t in TOOLS},
                    "agent_user_exists": agent_user_exists(),
                    # Proves the CLI starts unprivileged, which is what makes
                    # --dangerously-skip-permissions usable in this image.
                    "claude_version_as_agent": claude_version_as_agent(),
                    # Proves the agent can run the installer it depends on for
                    # every Python library it uses.
                    "uv_version_as_agent": uv_version_as_agent(),
                    # Telemetry. Both Claude Code switches have to be on for
                    # any signal to exist; telemetry_counters is null until the
                    # collector starts, which happens on the first job. Once a
                    # run is under way it answers "did the traces, the cost
                    # metrics and the events actually leave this VM", per
                    # signal, without querying CloudWatch at all.
                    "tracing_enabled": tracing_enabled(),
                    "telemetry_config": telemetry_config(),
                    "telemetry_counters": telemetry_counters(),
                },
            )
        else:
            self._json(200, {"status": "ok"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""

        if self.path == "/run":
            if not bedrock_enabled():
                self._json(500, {"error": "CLAUDE_CODE_USE_BEDROCK not configured"})
                return

            try:
                body = json.loads(raw or b"{}")
            except Exception as e:
                self._json(400, {"error": f"invalid JSON: {e}"})
                return

            required = ["run_id", "input_uri", "output_uri", "region"]
            missing = [f for f in required if not body.get(f)]
            if missing:
                self._json(400, {"error": f"missing fields: {missing}"})
                return
            if not RUN_ID_RE.match(str(body["run_id"])):
                self._json(400, {"error": "run_id must match [A-Za-z0-9._-]{1,128}"})
                return
            if body.get("vars") is not None and not isinstance(body["vars"], dict):
                self._json(400, {"error": "vars must be an object"})
                return

            # microvm_id is optional on purpose: without it the VM simply does
            # not self-terminate and the idlePolicy reaps it instead. That is a
            # degraded outcome, not a reason to refuse the work. prompt_uri is
            # optional too — the baked prompt is the fallback.
            # 202 first, then run in background.
            self._json(
                202,
                {
                    "status": "accepted",
                    "run_id": body["run_id"],
                    "will_self_terminate": bool(body.get("microvm_id")),
                },
            )
            threading.Thread(
                target=run_job_and_finish,
                args=(body,),
                daemon=True,
            ).start()
            return

        # Any other POST (lifecycle hooks) — always 200.
        self._json(200, {"status": "ok"})


class ThreadedHTTP(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    os.makedirs(RUNS_ROOT, exist_ok=True)
    logger.info(f"bedrock enabled: {bedrock_enabled()} (model {model_id()})")
    logger.info(f"default language: {language_name()}")
    logger.info(f"baked prompt present: {os.path.isfile(BAKED_PROMPT)}")
    logger.info(
        "tools: "
        + ", ".join(
            f"{t}={'yes' if shutil.which(t) else 'no'}" for t in TOOLS
        )
    )
    logger.info(f"agent user present: {agent_user_exists()}")
    server = ThreadedHTTP(("0.0.0.0", PORT), Handler)
    logger.info(f"claude-agent listening on 0.0.0.0:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
