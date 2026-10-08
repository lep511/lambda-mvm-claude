# claude-agent image — Claude Code as an autonomous agent in a MicroVM.
#
# A task-agnostic agent runtime: the image is Claude Code plus a toolbox, and
# the job it performs comes from agent-prompt.md, which run-agent.sh uploads
# with every run. Unlike module-2.1's reviewer, which pastes a diff into the
# prompt and gets a one-shot answer, this agent is handed a DIRECTORY and has
# to work it out itself — so it actually calls tools (Bash/Read/Write).
#
# app.py returns 202 from POST /run, runs the agent in a background thread,
# uploads whatever it left in the workspace's output/, and then calls
# TerminateMicrovm on itself. There is no orchestrator.
#
# Deliberately kept structurally identical to
# module-2.1-claude-code/reviewer-claude/Dockerfile, which is known to build.
# The only differences are: poppler-utils in the apt list, the non-root `agent`
# user, this lab's ENV block, and no OpenTelemetry collector.

FROM python:3.12-slim

# System dependencies — the agent's toolbox.
#
# What is in here is only what the agent CANNOT install for itself: apt packages
# need root, and the agent runs unprivileged (see the `agent` user below). So
# poppler-utils (pdftotext/pdfinfo) is baked in for the PDF task in prompts/ —
# the Read tool's document path is unreliable through Bedrock, and piping a whole
# PDF into the context burns it for no benefit. Adding another such tool (OCR is
# one package, tesseract-ocr) is an image change and needs a rebuild.
#
# Python libraries are the opposite case, and they are deliberately NOT here:
# the agent installs its own with uv at run time. Nothing in requirements.txt is
# for the agent to import — see that file.
RUN apt-get update && apt-get install -y \
    git \
    curl \
    unzip \
    poppler-utils \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 (aarch64 — Lambda MicroVMs run on ARM64)
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o awscliv2.zip \
    && unzip -q awscliv2.zip \
    && ./aws/install \
    && rm -rf awscliv2.zip aws/

# uv — Astral's Python package/project manager. This is how the agent gets
# every Python library it uses, so it is load-bearing rather than a convenience:
# without it a task can only reach the standard library. It works at run time
# because the image is launched with the INTERNET_EGRESS network connector
# (build-image.sh, --egress-network-connectors) — drop that connector and every
# dependency install inside the VM starts failing.
#
# Installed into /usr/local/bin rather than the default ~/.local/bin: the
# installer runs as root here, so the default would put it in /root/.local/bin,
# which is exactly the place the unprivileged `agent` user cannot read. One
# shared location keeps a single PATH working for both app.py (root) and the
# CLI it spawns. UV_NO_MODIFY_PATH stops the installer editing shell profiles
# it has no reason to touch — /usr/local/bin is already on PATH.
#
# Two things the agent should know about using it unprivileged (every file in
# prompts/ says so, because a task depends on them): `uv pip install --system`
# writes to /usr/local/lib and will fail as `agent`, so the way in is `uv run
# --with <lib>`, a `uv venv` in the job workspace, or `uvx` for one-off CLI
# tools; and the cache lands under $HOME/.cache/uv, which app.py points at
# /home/agent — writable, and discarded with the VM.
#
# Unpinned, like the AWS CLI and the Claude Code CLI above: the image is rebuilt
# often enough that a pin would mostly go stale. `uv --version` runs in the same
# layer so a bad download fails the build here rather than mid-run.
RUN curl -fsSL https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh \
    && uv --version && uvx --version

# Pin uv to the interpreter this image already has (3.12, from the base image)
# instead of letting it fetch a managed one. A download would work — the VM has
# internet egress — but it would be 30+ seconds of a run's budget spent to get
# the Python that is already installed, and when it *cannot* be had this fails
# with a clear message rather than retrying into a timeout.
ENV UV_PYTHON_DOWNLOADS=never

# OpenTelemetry Collector Contrib (aarch64). Claude Code exports its session
# spans over OTLP but cannot SigV4-sign them, so this collector signs and
# forwards them to CloudWatch's OTLP traces endpoint. Contrib, not core —
# sigv4auth is a contrib extension. Pinned: a floating version would drift the
# image, and a collector that fails to start takes the run's whole trace with
# it. What to do with the spans once they arrive: ../TELEMETRY.md.
ARG OTELCOL_VERSION=0.162.0
RUN curl -fsSL "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_arm64.tar.gz" \
      -o /tmp/otelcol.tar.gz \
    && tar -xzf /tmp/otelcol.tar.gz -C /usr/local/bin otelcol-contrib \
    && rm /tmp/otelcol.tar.gz \
    && otelcol-contrib --version

# Node.js (required for Claude Code CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (headless)
RUN npm install -g @anthropic-ai/claude-code

# The RUNTIME's Python dependencies — app.py's, not the agent's.
#
# They go into a venv at /opt/agent-runtime instead of the system interpreter,
# and that is the whole mechanism behind "the agent brings its own libraries":
# `python3` as seen by the agent is the bare base-image interpreter, standard
# library only, so a task cannot accidentally depend on something that happens
# to be lying around in site-packages and then break the day it is removed.
# What the agent needs, the agent installs — with uv, in its own workspace, per
# run. The venv is off PATH and is only ever named by the CMD at the bottom.
#
# Installed with uv rather than pip because uv is already here and resolves this
# in about a second; the `import boto3` check keeps a broken venv a BUILD
# failure, where the log is readable, instead of a VM that boots and dies on
# every job (app.py cannot upload artifacts or terminate its own VM without it).
#
# WORKDIR is set here rather than further down so requirements.txt lands beside
# app.py: it stays readable inside the VM, which is how you answer "what is
# actually installed in here?" without rebuilding.
WORKDIR /workspace

COPY requirements.txt .
RUN uv venv /opt/agent-runtime \
    && uv pip install --python /opt/agent-runtime/bin/python \
        --no-cache -r requirements.txt \
    && /opt/agent-runtime/bin/python -c "import boto3; print(boto3.__version__)"

# ── The non-root user, and why it exists ─────────────────────────────────────
#
# Claude Code refuses --dangerously-skip-permissions when it is running as
# root. The check is, in effect:
#
#   if (getuid() === 0 && IS_SANDBOX !== "1" && !CLAUDE_CODE_BUBBLEWRAP)
#     → "cannot be used with root/sudo privileges" → exit(1)
#
# This image is built from a Dockerfile but RUNS AS A MICROVM, so none of the
# container indicators the CLI looks for are present. Rather than setting a
# bypass variable, the agent simply runs unprivileged: with getuid() != 0 the
# check never fires, and the flag ends up used as intended — an unprivileged
# user inside an isolated, single-use VM.
#
# app.py itself stays root (it binds :9000 and needs setuid to drop privileges
# for the child). It creates /workspace/runs at boot and chowns each job
# directory to `agent`, so nothing here needs to pre-create or chown anything.
#
# No fixed --uid: nothing depends on the number. The CLI is NOT run during the
# build either — executing it here is the one step that could hang rather than
# fail, and a hung build surfaces as a generic "Build workflow was interrupted
# by an exception" with no log to read.
RUN useradd --create-home --shell /bin/bash agent

# Claude Code -> Amazon Bedrock. Credentials come from the MicroVM execution
# role at runtime (no API key is baked in). AWS_REGION is intentionally NOT
# pinned here because the workshop is multi-region; app.py sets it per request
# from the incoming job payload.
ENV CLAUDE_CODE_USE_BEDROCK=1
ENV ANTHROPIC_MODEL=us.anthropic.claude-opus-5

# Default for the prompt's {{LANGUAGE}} placeholder, used when a run does not
# override it with --var LANGUAGE=<code>. build-image.sh re-passes it via
# --environment-variables so it can be changed without editing this file.
ENV AGENT_LANGUAGE=es

# ── Claude Code -> OpenTelemetry ─────────────────────────────────────────────
#
# Session tracing needs BOTH switches: CLAUDE_CODE_ENABLE_TELEMETRY is the
# master gate and CLAUDE_CODE_ENHANCED_TELEMETRY_BETA is what turns the
# interaction / LLM-request / tool-execution spans on. One without the other
# produces an image that looks instrumented and emits nothing.
# build-image.sh re-passes both from AGENT_TRACING, so tracing can be turned
# off for a build without editing this file; app.py reads the same two
# variables and skips starting the collector when either is off.
ENV CLAUDE_CODE_ENABLE_TELEMETRY=1
ENV CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1

# All three signals, because they answer different questions and the agent
# emits them whether or not anyone collects them:
#   traces  — what the agent DID: one span per interaction, Bedrock call and
#             tool execution, with the command and its result attached
#   metrics — what it COST: claude_code.cost.usage in USD and
#             claude_code.token.usage by type, plus session/lines/active-time
#   logs    — the event stream: user_prompt, assistant_response, tool_result,
#             tool_decision, api_request, api_error, ... queryable per run
# The collector fans them out to three CloudWatch destinations; stdout still
# goes to the image's log group independently of all this.
ENV OTEL_TRACES_EXPORTER=otlp
ENV OTEL_METRICS_EXPORTER=otlp
ENV OTEL_LOGS_EXPORTER=otlp

# Point at the in-VM collector. Setting the protocol explicitly is not
# optional: Claude Code has no default protocol, so an unset value here is an
# exporter that never ships. One endpoint serves all three signals — the OTLP
# receiver in otel-collector.yaml listens on /v1/traces, /v1/metrics and
# /v1/logs of the same port, and it is http only.
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
ENV OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
ENV OTEL_SERVICE_NAME=mvm-claude-agent

# ── What the telemetry is allowed to carry ───────────────────────────────────
#
# Everything content-bearing is redacted by default, and for this lab the
# content IS the product: the rendered task prompt, the bash commands the agent
# chose, what those commands returned, and the model's own text. Each gate is
# separate, so they are listed one by one with what it buys.
#
# The consequence is the same for all four: prompt text, input filenames and
# tool output land in CloudWatch. ../TELEMETRY.md, "What ends up in a span",
# says how to narrow it.
ENV OTEL_LOG_USER_PROMPTS=1
# Assistant text in events. It already defaults to the value of
# OTEL_LOG_USER_PROMPTS, but set explicitly so a future change to that
# fallback cannot silently drop the model's answers.
ENV OTEL_LOG_ASSISTANT_RESPONSES=1
# Tool parameters and inputs: `full_command` on Bash, file paths, patterns.
ENV OTEL_LOG_TOOL_DETAILS=1
# Tool OUTPUT, as a tool.output span event: what pdftotext, python and uv
# actually printed. This is the half that was missing — the commands were
# visible and their results were not, which is exactly the gap when a run
# produces a wrong number and you want to know what the agent was looking at.
ENV OTEL_LOG_TOOL_CONTENT=1

# The real limiter on content size is Claude Code's own, not the OTel SDK's.
# Setting the SDK limits alone (as this image used to) does nothing: content is
# capped at CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH first — 61440 by default —
# and when an SDK limit is LOWER, Claude Code truncates there instead so its
# [TRUNCATED] marker still fits. So the two are pinned together, and the SDK
# limits are kept above the content limit on purpose. 60 KB is also what
# CloudWatch-side attribute limits are sized for; raising it risks the backend
# rejecting the attribute rather than truncating it.
ENV CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH=61440
ENV OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT=65536
ENV OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT=65536

# ── Cardinality ──────────────────────────────────────────────────────────────
#
# Metrics reach CloudWatch as EMF, where every distinct attribute combination
# is a billable custom metric. One VM is one session is one run, so session.id
# would only duplicate what agent.run_id already says (app.py stamps it as a
# resource attribute, and resource attributes are included by default).
# app.version is the opposite trade: it is one value per image, costs nothing,
# and is the first thing you want when a run misbehaves after a rebuild.
# account_uuid is off because on Bedrock there is no Anthropic account to
# attribute to.
ENV OTEL_METRICS_INCLUDE_SESSION_ID=false
ENV OTEL_METRICS_INCLUDE_VERSION=true
ENV OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false
# Default is already true, and it is load-bearing rather than incidental: these
# are the keys app.py stamps (agent.run_id and friends), and the EMF exporter
# turns them into the dimensions that make per-run cost a query. Pinned so a
# change of default cannot quietly take per-run attribution away.
ENV OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES=true
# Also the default, also pinned: EMF expects deltas. Cumulative would not fail,
# it would publish wrong numbers — each datapoint restating the session total.
ENV OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta

# ── Export intervals ─────────────────────────────────────────────────────────
#
# `claude -p` is short-lived and this VM terminates itself seconds after the
# job finishes, so every default here is too slow: the metrics default of 60s
# would leave up to a minute of cost data in the CLI's buffer, relying entirely
# on its shutdown flush. app.py drains the COLLECTOR before terminating, but it
# cannot drain what the CLI has not handed over yet.
ENV OTEL_TRACES_EXPORT_INTERVAL=2000
ENV OTEL_LOGS_EXPORT_INTERVAL=2000
ENV OTEL_METRIC_EXPORT_INTERVAL=10000
ENV CLAUDE_CODE_OTEL_SHUTDOWN_TIMEOUT_MS=5000

# ── Detailed beta tracing: deliberately OFF ──────────────────────────────────
#
# It would add the richest attributes of all — the new user messages and tool
# results sent with each request (`new_context`), the system prompt preview and
# the model's output on every llm_request span — and for `claude -p` sessions
# it needs no org allowlisting. Two reasons it is not on:
#
#   1. It is a PAIR: ENABLE_BETA_TRACING_DETAILED=1 plus BETA_TRACING_ENDPOINT,
#      and setting it takes over delivery of logs AND traces, which then go to
#      that endpoint instead of through the exporters configured above. Point
#      it anywhere but this collector and both signals vanish silently.
#   2. The volume is a different order: every request carries its full new
#      context and the model's answer.
#
# To turn it on, both variables together, and the endpoint must be the in-VM
# collector:
#   AGENT_TRACING_DETAILED=1 ./build-image.sh
# which is what build-image.sh wires up. ../TELEMETRY.md has the detail.

# WORKDIR is already /workspace, set above with the dependency install.
COPY app.py .

# The collector's config. app.py launches otelcol-contrib with this path, so a
# build that forgets to ship it produces a VM where every run loses its trace
# — build-image.sh checks the file exists before it zips, for that reason.
COPY otel-collector.yaml .

# The FALLBACK task definition. The live one is uploaded per run and wins; this
# copy is what keeps the image self-sufficient — a job with no prompt_uri (the
# smoke test, or a direct run-microvm call) still has something to do.
COPY agent-prompt.md .

# Single port for both the /run endpoint and lifecycle hooks
EXPOSE 9000

# The runtime venv's interpreter, NOT `python3`: boto3 lives only in there (see
# the install above). `python3` is left bare on purpose for the agent, so if this
# line ever says python3 again the VM boots, fails to import boto3 and no job
# ever completes.
CMD ["/opt/agent-runtime/bin/python", "app.py"]
