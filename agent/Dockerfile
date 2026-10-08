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
# poppler-utils (pdftotext/pdfinfo) is here for the PDF summarisation task in
# prompts/: the Read tool's document path is unreliable through Bedrock, and
# piping a whole PDF into the context burns it for no benefit. Tools stay in the
# image whether or not the active task uses them, so switching tasks needs no
# rebuild — adding a tool does (OCR, for instance, is one package:
# tesseract-ocr). Python libraries go in requirements.txt instead.
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

# Node.js (required for Claude Code CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (headless)
RUN npm install -g @anthropic-ai/claude-code

# Python dependencies, from requirements.txt rather than inline, the same way
# the orchestrators in this workshop declare theirs. The file is the source of
# truth and build-image.sh zips it alongside this Dockerfile; what is in it and
# why is documented there. The spreadsheet libraries are the same shape as
# poppler-utils above — a CLI extractor the agent can pipe (xlsx2csv is to
# .xlsx what pdftotext is to .pdf) plus libraries for when a flat dump is not
# enough. All of them are pure Python, so they cost the image almost nothing.
#
# WORKDIR is set here rather than further down so requirements.txt lands beside
# app.py: it stays readable inside the VM, which is how you answer "what is
# actually installed in here?" without rebuilding.
WORKDIR /workspace

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

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

# No OpenTelemetry collector here, unlike module-2.1's reviewer: tracing was
# not asked for in this lab, and leaving it out keeps the image to the one
# thing it is teaching.

# WORKDIR is already /workspace, set above with the dependency install.
COPY app.py .

# The FALLBACK task definition. The live one is uploaded per run and wins; this
# copy is what keeps the image self-sufficient — a job with no prompt_uri (the
# smoke test, or a direct run-microvm call) still has something to do.
COPY agent-prompt.md .

# Single port for both the /run endpoint and lifecycle hooks
EXPOSE 9000

CMD ["python3", "app.py"]
