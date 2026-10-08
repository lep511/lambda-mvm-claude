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
  5. Background thread calls TerminateMicrovm on ITSELF

Step 4 before step 5 is not cosmetic: _status.json is the only completion
signal run-agent.sh gets, so it has to be in S3 before this VM stops
existing. The `idlePolicy` the VM was launched with is the backstop for a
crash that never reaches step 5 at all.

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
import shutil
import subprocess
import threading
import time
import traceback
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

# Tools the image ships with, reported by /health. Task-specific ones live here
# too (prompts/summary-docs.md needs poppler, prompts/xls-analysis.md needs
# xlsx2csv) — the runtime only reports them, it is the prompt that decides which
# ones matter. Reporting them is what lets the smoke test rule out a missing
# extractor before a job burns minutes discovering it.
TOOLS = ("pdftotext", "pdfinfo", "xlsx2csv", "git", "aws")

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


_claude_version_lock = threading.Lock()
_claude_version = None


def claude_version_as_agent() -> str:
    """Run `claude --version` as the unprivileged agent user.

    This is the single most informative probe in this image. If the CLI starts
    as `agent`, then getuid() != 0 and the root gate on
    --dangerously-skip-permissions cannot fire — which is the one new way this
    lab can break compared to module-2.1's reviewer. It also costs no Bedrock
    tokens, so the smoke test can assert on it freely.

    Cached: it spawns a process, and /health gets polled.
    """
    global _claude_version
    with _claude_version_lock:
        if _claude_version is not None:
            return _claude_version
        try:
            proc = subprocess.run(
                ["claude", "--version"],
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
                timeout=60,
            )
            _claude_version = (
                (proc.stdout or proc.stderr or "").strip() or f"exit {proc.returncode}"
            )
        except Exception as e:
            _claude_version = f"error: {e}"
        return _claude_version


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

    Listing the prefix needs s3:ListBucket on the bucket, which the workshop's
    execution role does NOT have out of the box — claude-agent's
    grant-permissions.sh is what adds it. boto3 is used rather than
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


def agent_env(region: str) -> dict:
    """Environment for the unprivileged child.

    Resolves concrete credentials and passes them as the three standard env
    vars. The execution role's credentials may be delivered through a path the
    `agent` user cannot read, and every AWS SDK puts env vars first in its
    provider chain, so freezing them here is what gets Bedrock working for a
    non-root child regardless of the delivery mechanism.
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
        }
    )
    return env


# ── Running the agent ─────────────────────────────────────────────────────────

# Deliberately says nothing about any particular task: it points at CLAUDE.md
# and states the workspace contract. Everything task-specific is in the prompt
# file, which is where it can be changed without touching this image.
AGENT_BOOTSTRAP = (
    f"Read ./CLAUDE.md in this directory and carry out the job it describes, "
    f"start to finish. Your input files are in ./{INPUT_DIR}/. Write every file "
    f"you want to keep into ./{OUTPUT_DIR}/ — that directory is the only thing "
    f"that leaves this machine. Nobody is watching this session, so do not stop "
    f"to ask questions, and do not stop until the job is complete."
)


def run_claude(job_dir: str, env: dict, timeout: int) -> tuple[str, str]:
    """Run `claude -p` as the agent user. Returns (stdout, last_error).

    Claude Code makes many Bedrock calls over an agentic run, and a transient
    4xx/5xx on any of them makes the CLI exit non-zero even though a retry
    usually succeeds — so the whole invocation is retried with exponential
    backoff, the same way module-2.1's reviewer does it. A timeout is terminal
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
    run_id = str(body["run_id"])
    input_uri = body["input_uri"]
    output_uri = body["output_uri"].rstrip("/")
    region = body["region"]

    started = time.monotonic()
    job_dir = os.path.join(RUNS_ROOT, run_id)
    in_dir = os.path.join(job_dir, INPUT_DIR)
    out_dir = os.path.join(job_dir, OUTPUT_DIR)

    try:
        shutil.rmtree(job_dir, ignore_errors=True)
        os.makedirs(in_dir, exist_ok=True)
        os.makedirs(out_dir, exist_ok=True)

        s3 = boto3.client("s3", region_name=region)

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
        render_prompt(job_dir, template, input_names, run_id, body.get("vars") or {})
        chown_tree(job_dir)

        timeout = int(os.environ.get("CLAUDE_TIMEOUT", "1500"))
        stdout, error = run_claude(job_dir, agent_env(region), timeout)

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
    the workshop would pay for the gap. The id is passed in by run-agent.sh
    because a VM has no way to ask what it is.

    Needs lambda:TerminateMicrovm on the execution role — that is one of the
    grants in grant-permissions.sh. Absence of the id, or a failure here, is
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
    """Run the task, publish the result, then shut this MicroVM down.

    The ordering is the contract: status to S3 first, terminate second, and
    both happen whether the job succeeded or not.
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
        self_terminate(body)


# ── HTTP handler ──────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
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
