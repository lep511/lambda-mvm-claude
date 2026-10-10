# Seeing what the agent did: tracing a run end to end

Every run of this project leaves evidence behind. Two kinds are obvious — the files
in `output/<run-id>/` and the agent's stdout in the MicroVM's log group. The
rest is OpenTelemetry, and Claude Code emits **three signals** that answer three
different questions:

| Signal | Answers | Lands in |
| --- | --- | --- |
| **Traces** | *What did it do?* One span per interaction, Bedrock call and tool execution, with the command, its output and the prompt attached | `aws/spans`, via Transaction Search |
| **Metrics** | *What did it cost?* `claude_code.cost.usage` in USD and `claude_code.token.usage` by type, plus session, lines-of-code and active-time counters | CloudWatch Metrics, namespace `ClaudeCodeAgent` |
| **Events** | *What happened, in order?* `user_prompt`, `assistant_response`, `tool_result`, `tool_decision`, `api_request`, `api_error`, … | log group `/aws/claude-agent/events` |

All three are exported from inside the VM, and drained before it terminates
itself. That is what this document is about: turning it on once per account, and
then reading it.

```
┌─ MicroVM (una por ejecución, duración de minutos) ───────────────────────┐
│                                                                          │
│  ┌──────────────────┐   OTLP/HTTP         ┌───────────────────────────┐  │
│  │ claude -p        │   127.0.0.1:4318    │ otelcol-contrib           │  │
│  │ (user: agent)    │  --------------->   │ (collector)               │  │
│  │                  │  /v1/traces         │                           │  │
│  │                  │  /v1/metrics        │                           │  │
│  │                  │  /v1/logs           │                           │  │
│  └──────────────────┘                     └──┬────────┬────────┬──────┘  │
│                                              │        │        │         │
│  app.py: 1) inicia el collector      otlphttp│    EMF │   logs │         │
│          2) lo drena antes de        + SigV4 │        │        │         │
│             TerminateMicrovm                 │        │        │         │
└──────────────────────────────────────────────┬────────┬────────┬─────────┘
                                               ▼        ▼        ▼
                        xray.<region>.amazonaws.com   CloudWatch   /aws/claude-agent/
                              /v1/traces               Metrics          events
                                   │                 (ClaudeCodeAgent)     │
                         X-Ray Transaction Search          │               │
                                   │                       │               │
                     ┌─────────────┴───────────┐           │               │
                     ▼                         ▼           ▼               ▼
            log group `aws/spans`    Consola de CloudWatch   Dashboards   Logs
            (Logs Insights)          (Transaction Search)    y alarmas    Insights
```

**Why the collector is there at all.** Claude Code speaks OTLP but cannot
SigV4-sign a request, and every CloudWatch destination requires signed
requests. So a collector runs beside the agent in the same VM, signs with the
execution role's credentials, and fans the three signals out. It is
`otelcol-contrib`, not the core build, because `sigv4auth`, `awsemf` and
`awscloudwatchlogs` are all contrib components.

Metrics go as **embedded metric format** through CloudWatch Logs rather than to
the OTLP metrics endpoint: EMF works with plain role credentials, which is the
one auth path this VM is guaranteed to have.

---

## One-time setup (per account and region)

Both steps are account-level, not image-level. Skip either one and every run
still succeeds, delivers its artifacts, and produces no trace — which is the
single most confusing failure mode in this document, so do these first.

### 1. Let the execution role write telemetry

```bash
./create-roles.sh
```

Two of the seven statements it puts on the MicroVM execution role exist only
for telemetry:

| Grant | For |
| --- | --- |
| `xray:PutTraceSegments`, `xray:PutTelemetryRecords` | Traces. These are the actions the OTLP traces endpoint authorizes against; AWS's managed equivalent is `AWSXrayWriteOnlyPolicy` |
| `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` on `/aws/claude-agent/*` | **Both** metrics and events — EMF metrics and the event stream are written through CloudWatch Logs, so cost data depends on these too |

A third one is adjacent and worth knowing about: the same four `logs:*` actions
on `/aws/lambda-microvms/*` carry the VM's own stdout, which is where
`app.py`'s `telemetry drained` summary appears. Without it you lose the cheapest
diagnostic for everything below.

Verify:

```bash
aws iam get-role-policy \
  --role-name "${MVM_EXECUTION_ROLE_ARN##*/}" \
  --policy-name ClaudeAgentExecutionPolicy
```

### 2. Enable Transaction Search

This one is **traces only** — metrics and events do not depend on it. Spans
only reach the X-Ray OTLP endpoint if Transaction Search is on; it is what
routes them into the `aws/spans` log group.

In the console: **CloudWatch → Application Signals → Transaction Search →
Enable Transaction Search**, tick *ingest spans as structured logs*, and pick an
indexing percentage (1% is free and is enough — you still get all spans in
`aws/spans`; indexing only drives trace summaries).

Or with the CLI, which is three calls:

```bash
# a) let X-Ray write into the span log groups
aws logs put-resource-policy \
  --policy-name TransactionSearchXRayAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"TransactionSearchXRayAccess\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"xray.amazonaws.com\"},
      \"Action\": \"logs:PutLogEvents\",
      \"Resource\": [
        \"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNTID}:log-group:aws/spans:*\",
        \"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNTID}:log-group:/aws/application-signals/data:*\"
      ],
      \"Condition\": {
        \"ArnLike\": {\"aws:SourceArn\": \"arn:aws:xray:${AWS_REGION}:${AWS_ACCOUNTID}:*\"},
        \"StringEquals\": {\"aws:SourceAccount\": \"${AWS_ACCOUNTID}\"}
      }
    }]
  }" --region "${AWS_REGION}"

# b) send spans to CloudWatch Logs
aws xray update-trace-segment-destination \
  --destination CloudWatchLogs --region "${AWS_REGION}"

# c) optional: how much to index as trace summaries
aws xray update-indexing-rule --name "Default" \
  --rule '{"Probabilistic": {"DesiredSamplingPercentage": 1}}' \
  --region "${AWS_REGION}"
```

Verify, and expect `ACTIVE`:

```bash
aws xray get-trace-segment-destination --region "${AWS_REGION}"
# { "Destination": "CloudWatchLogs", "Status": "ACTIVE" }
```

After enabling it, allow **up to 10 minutes** before spans become searchable.
A run done inside that window is not lost — it is just not queryable yet.

---

## Turning it on in the image

Telemetry is baked, so it is a rebuild (the task is not — see `README.md`):

```bash
agent/build-image.sh                        # all three signals, the default
AGENT_TRACING=0 agent/build-image.sh        # no telemetry at all
AGENT_TRACING_DETAILED=1 agent/build-image.sh   # + detailed spans, see below
```

`AGENT_TRACING` drives both Claude Code switches together —
`CLAUDE_CODE_ENABLE_TELEMETRY` and `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA`. One
without the other is the silent-failure shape: an image that looks instrumented
and emits nothing. `app.py` reads the same pair and does not start the collector
when they are off, so an untraced image costs nothing at run time.

The smoke test asserts the image half of this and spends no Bedrock tokens:

```bash
agent/test-image.sh
#   ✓ tracing enabled (both Claude Code telemetry switches baked in)
#   ✓ otelcol-contrib present (spans can be signed and forwarded)
```

### What the signals are allowed to carry

Claude Code redacts every content-bearing attribute by default, and each kind
has its own gate. For this project the content *is* the product, so all four are on:

| Variable | What it adds | Where |
| --- | --- | --- |
| `OTEL_LOG_USER_PROMPTS=1` | The rendered task prompt and user messages | `user_prompt` events, `interaction` span |
| `OTEL_LOG_ASSISTANT_RESPONSES=1` | The model's own text | `assistant_response` events |
| `OTEL_LOG_TOOL_DETAILS=1` | Tool inputs: `full_command` on Bash, file paths, patterns — and real agent/skill/MCP names on the cost and token counters | `tool_result` / `tool_decision` events, `tool` span |
| `OTEL_LOG_TOOL_CONTENT=1` | Tool **output**: what `python`, `uv` and `pdftotext` actually printed | `tool.output` span event |

Two notes on size, both of which bite:

- The limiter is `CLAUDE_CODE_OTEL_CONTENT_MAX_LENGTH` (61440, i.e. 60 KB), not
  the OTel SDK's attribute limits. Setting only `OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT`
  — as this image did at first — changes nothing, because content is truncated
  at Claude Code's limit first. When an SDK limit is *lower*, Claude Code
  truncates there instead so its `[TRUNCATED]` marker still fits, which is why
  the image keeps the SDK limits above the content limit.
- 60 KB is sized for backends that cap attribute values at 64 KB. Raising it
  risks the backend rejecting an attribute outright rather than truncating it.

### Detailed beta tracing (opt-in)

`AGENT_TRACING_DETAILED=1` adds the richest attributes Claude Code has: the new
user messages and tool results sent with each request (`new_context`), the
system prompt preview, `tool_input`, and the model's output on every
`llm_request` span — plus `claude_code.hook` spans. In `claude -p` sessions it
needs no organisation allowlisting, which is why it is available here at all.

It is off by default for two reasons worth knowing before you turn it on:

1. **It is a pair**, `ENABLE_BETA_TRACING_DETAILED=1` *and*
   `BETA_TRACING_ENDPOINT`, and setting it takes over delivery of **logs and
   traces**: both go to that endpoint instead of through the configured
   exporters. `build-image.sh` therefore hard-codes the endpoint to the in-VM
   collector — point it anywhere else and two of your three signals vanish with
   no error anywhere.
2. **The volume is a different order.** Every request carries its full new
   context and the model's answer, on top of what the gates above already send.

---

## How a run is labelled

`app.py` stamps resource attributes onto everything a run emits — spans, metric
datapoints and events alike — which is what makes the three signals joinable to
each other and to the rest of the evidence:

| Attribute | Value | Why you care |
| --- | --- | --- |
| `service.name` | `mvm-claude-agent` | Separates this project from anything else reporting into the same account |
| `service.namespace` | `lambda-mvm-claude` | |
| `deployment.environment.name` | `claude-agent` | |
| `agent.run_id` | e.g. `20261008-002347` | **The join key.** Same string as `output/<run-id>/` and the run's S3 prefix |
| `agent.task` | the prompt's source URI, or `image:agent-prompt.md` | Which task definition ran — the per-run upload or the baked fallback |
| `agent.model` | e.g. `us.anthropic.claude-opus-5` | Compare two runs of one task across models |

Values are sanitised before they go in: `OTEL_RESOURCE_ATTRIBUTES` is a flat
`k=v,k=v` list with no escaping, so a `,` or `=` inside a value would silently
split into attributes nobody can query.

On **metrics** those same attributes become EMF dimensions, which is what makes
"what did *this* run cost" answerable — and is also the cardinality bill: each
new `agent.run_id` is a new metric stream. The image keeps that in check by
dropping the attributes that would duplicate it (`OTEL_METRICS_INCLUDE_SESSION_ID=false`,
since one VM is one session is one run) and keeping the cheap, useful one
(`OTEL_METRICS_INCLUDE_VERSION=true` — which CLI version produced this, the
first thing you want after a rebuild). Before pointing this at something that
runs thousands of jobs, turn off `resource_to_telemetry_conversion` in
`agent/otel-collector.yaml`.

Spans, metrics and events all come from Claude Code's own instrumentation, named
by the CLI rather than by this project, and the span schema in particular is a beta
feature whose attribute keys can change between CLI versions. So the first query
below (dump one record) is worth more than any list this document could
hard-code.

### One trace per run

Claude Code starts a new trace per interaction, which would make a 50-turn run
50 unrelated traces. The document's way out is that in `claude -p` sessions —
exactly what this project runs — Claude Code **reads `TRACEPARENT` from its own
environment** and parents each `claude_code.interaction` span under it, and
stamps the same ids on the event records. So `app.py`:

1. mints one W3C trace context per job, before anything can emit a span;
2. passes it to the agent as `TRACEPARENT` (`agent_env`);
3. publishes its own `claude_agent.run` span as the root, carrying the run's
   duration, outcome, input count and artifact count;
4. writes the `trace_id` into `_status.json`.

The result is one trace per run: `claude_agent.run` at the top, every
interaction, Bedrock call and tool execution nested under it, and the events
carrying the same ids. The root span is published *before* the flush so it
ships with everything else, and it is posted as OTLP/JSON straight to the
collector — no OTel SDK, which is how the runtime venv keeps its single
dependency.

Two things to look for when checking it worked:

- `parent.source = env` on the interaction spans. `none` means the child never
  saw `TRACEPARENT` and started its own trace.
- `trace_id` in `_status.json`, which is the way from a delivered artifact
  straight to its trace:

```bash
aws s3 cp "s3://${ARTIFACTS_BUCKET}/claude-agent/runs/<run-id>/output/_status.json" - | jq -r .trace_id
```

---

## Viewing a run

### Transaction Search (the visual route)

**CloudWatch → Application Signals → Transaction Search**, then filter. The
useful starting filters:

```
attributes.agent.run_id = 20261008-002347      # one run, every span
resource.attributes.service.name = mvm-claude-agent   # this project, all runs
```

Click a `traceId` to get the waterfall: how long the agent spent thinking
versus running tools, which Bedrock calls were retried, and what each tool
received and returned.

### X-Ray trace map

**CloudWatch → X-Ray traces → Traces** (or **Trace Map**) over the same data,
which is the better view when you want latency distribution across runs rather
than one run's detail.

### Logs Insights on `aws/spans` (the precise route)

Select the **`aws/spans`** log group in **CloudWatch → Logs Insights**. Start by
dumping one span — the schema is OTel attribute names, so this is the
authoritative reference for what you can filter on:

```
fields @message
| limit 1
```

Then, with field names in hand:

```
# every span of one run, oldest first
fields @timestamp, name, attributes.agent.run_id
| filter attributes.agent.run_id = "20261008-002347"
| sort @timestamp asc
| limit 200
```

```
# which tools the agent chose, across all runs of this project
fields @timestamp, name, @message
| filter `resource.attributes.service.name` = "mvm-claude-agent"
| filter name like /tool/
| sort @timestamp desc
| limit 100
```

```
# only the spans that failed
fields @timestamp, name, @message
| filter `resource.attributes.service.name` = "mvm-claude-agent"
| filter `status.code` = "ERROR"
| sort @timestamp desc
| limit 50
```

Resource attributes are nested under `resource.attributes.*` and their dots need
backticks in Logs Insights; span attributes live under `attributes.*`. If a
filter returns nothing, check the name against the dump query before assuming
the span is missing — this is the most common reason a query looks empty.

The same from the CLI:

```bash
QID=$(aws logs start-query --log-group-name "aws/spans" \
  --start-time "$(($(date +%s) - 3600))" --end-time "$(date +%s)" \
  --query-string 'fields @timestamp, name, @message | filter attributes.agent.run_id = "20261008-002347" | sort @timestamp asc | limit 200' \
  --region "${AWS_REGION}" --query queryId --output text)

aws logs get-query-results --query-id "${QID}" --region "${AWS_REGION}"
```

### What the run cost (metrics)

In the console: **CloudWatch → Metrics → All metrics → `ClaudeCodeAgent`**, then
pick a dimension set — `agent.run_id` is one run, `agent.task` is one task
across runs, `agent.model` compares models.

From the CLI, use **Metrics Insights**, not `get-metric-statistics`. Claude Code
publishes each datapoint with its full attribute set, which here is **17
dimensions** (`agent.run_id`, `agent.task`, `app.version`, `effort`, `model`,
`query_source`, `os.version`, `user.id`, …), and `get-metric-statistics` matches
only an *exact, complete* dimension set — give it `agent.run_id` alone and it
returns zero datapoints and no error, which looks exactly like telemetry that
never arrived. Metrics Insights filters on one dimension:

```bash
# the dollar figure for one run
aws cloudwatch get-metric-data --region "${AWS_REGION}" \
  --start-time "$(date -u -d '2 hours ago' +%FT%TZ)" \
  --end-time "$(date -u +%FT%TZ)" \
  --metric-data-queries '[{
    "Id": "cost",
    "Period": 60,
    "Expression": "SELECT SUM(\"claude_code.cost.usage\") FROM \"ClaudeCodeAgent\" WHERE \"agent.run_id\" = '"'"'20261008-132911'"'"'"
  }]' --query 'MetricDataResults[0].Values'
# [0.1944745, 1.363689, 0.31502949999999996]   -> $1.87 so far
```

Swap the metric and add `GROUP BY` for the breakdowns that matter:

```sql
SELECT SUM("claude_code.token.usage") FROM "ClaudeCodeAgent"
  WHERE "agent.run_id" = '<run-id>' GROUP BY "type"     -- input/output/cacheRead/cacheCreation
SELECT SUM("claude_code.cost.usage")  FROM "ClaudeCodeAgent" GROUP BY "agent.task"
SELECT SUM("claude_code.active_time.total") FROM "ClaudeCodeAgent" WHERE "agent.run_id" = '<run-id>'
```

Two limits worth knowing before you script around this: a request may carry
**exactly one** Metrics Insights query (a second one fails with "Maximum number
of queries (1) exceeded", so cost and tokens are two calls), and if you do want
`get-metric-statistics`, get the whole dimension set first with
`aws cloudwatch list-metrics --namespace ClaudeCodeAgent --metric-name
"claude_code.cost.usage"` and pass every pair it returns.

`agent/status.sh` already does the per-run version of all this — it prints the
dollar figure and the token total for a run, finished or in flight.

These are ordinary custom metrics, so they alarm and dashboard like any other —
a small-scale use is an alarm on `claude_code.cost.usage` summed across the
namespace, which catches a prompt that has started looping long before the bill
does.

### The event stream (logs)

One log group, one stream per run:

```bash
# every event of one run, in order
aws logs tail /aws/claude-agent/events --since 1h \
  --log-stream-names 20261008-122452 --region "${AWS_REGION}"
```

Each record is a JSON envelope: `body` is the event name on its own, and
everything worth reading is under `attributes.*`, with the run's identity under
`resource.attributes.*`. So the field names need the same backticks the span
queries need, and `body` alone tells you nothing — if a query over this group
returns rows whose only content is `claude_code.<something>`, see
`raw_log` in the troubleshooting table below.

In Logs Insights over `/aws/claude-agent/events`, the same discipline as with
spans — dump one record first, then filter on what you actually see:

```
fields @message
| limit 1
```

```
# the agent's own narration of a run: prompt, answers, tool results, in order
fields @timestamp, `attributes.event.name`, `attributes.prompt`,
       `attributes.response`, `attributes.tool_name`, `attributes.duration_ms`
| filter @logStream = "20261008-122452"
| sort @timestamp asc
| limit 500
```

```
# every API error across all runs, newest first
fields @timestamp, @logStream, `attributes.error`, `attributes.status_code`
| filter `attributes.event.name` = "api_error"
| sort @timestamp desc
| limit 50
```

Events are the right signal for "what happened and in what order" and for
audit-style questions; traces are better for "where did the time go". They carry
`prompt.id`, which ties every event produced while handling one prompt together.

### The run's own log group

Not spans, but the fastest answer to "did telemetry work at all". The runtime
and the collector share the MicroVM's log group:

```bash
aws logs tail /aws/lambda-microvms/mvm-claude-agent --since 30m --follow
```

Three lines matter:

| Line | Meaning |
| --- | --- |
| `starting otelcol-contrib for region <r> (warming up)` | The collector was launched for this job |
| `collector listening on 127.0.0.1:4318 after 27.3s of waiting` | It bound the port, and what the wait cost after the input download had already absorbed part of it |
| `telemetry drained: spans 143/143, metrics 24/24, logs 61/61, queued 0` | `app.py` drained all three signals before terminating the VM — each pair is sent/accepted |

A zero or a mismatch on one signal localises the problem immediately: spans
short means xray or Transaction Search, metrics or logs short means the
CloudWatch Logs grant. A `?` instead of a number means that exporter published
no verdict and the flush fell back to "nothing queued and nothing new arriving"
— normal, not an error. `no telemetry was produced; nothing to flush` means the
run never got as far as calling the model, and an `Exporting failed` line from
the collector names the cause directly.

**On that wait.** `otelcol-contrib` is a 379 MB static binary, and in a fresh
MicroVM its first exec demand-pages the whole thing while the runtime is
downloading the job's input. Measured cold, it took **66 seconds** from exec to
binding `:4318`. So `app.py` launches it as early as it can, lets it warm up
*during* the input download, and only blocks on the port immediately before
`claude` starts — the first thing that emits a span. Seconds of waiting there
are cheaper than a trace that begins in the middle of the run: Claude Code's
exporter posts every two seconds and drops silently when nothing is listening.
The budget is `COLLECTOR_START_TIMEOUT` (120 s) and a timeout is not fatal —
the job runs on, untraced.

---

## What ends up in a span

Worth knowing before pointing this at anything sensitive. The image sets
`OTEL_LOG_USER_PROMPTS=1` and `OTEL_LOG_TOOL_DETAILS=1`, and raises the
attribute length limit to 64 KiB, because an agentic run's value is in exactly
that detail — the rendered task prompt, the bash commands the agent chose, the
tool results it acted on. The consequence is that **prompt text and input
filenames land in CloudWatch**, in an account-wide log group.

What does not: AWS credentials are passed to the child as environment
variables, not as span attributes, and the artifacts themselves go to S3 rather
than into a span.

To narrow it, rebuild with the parts you want (all three are baked env vars in
`agent/Dockerfile`):

| Change | Effect |
| --- | --- |
| `OTEL_LOG_USER_PROMPTS=0` | Spans keep timings and structure, drop prompt text |
| `OTEL_LOG_TOOL_DETAILS=0` | Drops tool arguments and results |
| `AGENT_TRACING=0` on the build | No spans, no collector, nothing leaves the VM |

---

## Verifying the whole chain

In order, because each step depends on the one above it:

1. **Image** — `agent/test-image.sh` reports `tracing_enabled: true`,
   `otelcol-contrib` present, all three exporters set to `otlp` and the four
   content gates on. It reads them from `/health`'s `telemetry_config`, which
   is also where to look by hand when a rebuild changed something.
2. **Role** — `aws iam get-role-policy ... --policy-name
   ClaudeAgentExecutionPolicy` contains both the `ExportSpans` and the
   `ExportMetricsAndEvents` statements.
3. **Account** — `aws xray get-trace-segment-destination` says
   `CloudWatchLogs` / `ACTIVE` (traces only; metrics and events need nothing
   here).
4. **Run** — `./run-agent.sh`, then the log group shows
   `telemetry drained: spans N/N, metrics N/N, logs N/N` with every N > 0.
   `agent/status.sh` reads that line for you under `==> telemetry`, names any
   signal whose `sent` fell short of its `accepted` (those items died with the
   VM — nothing retries them), and groups the collector's own `Exporting
   failed` reasons, which is the part that says *why*. It cannot read
   `/health`'s `telemetry_counters` — there is no route to the VM from
   outside — so mid-run it has the collector's errors but not the drain, which
   app.py only reports as it shuts down.
5. **Query** — one per signal, since they fail independently:
   - `aws/spans` returns rows for `attributes.agent.run_id = "<run-id>"` (give
     it a minute, and up to 10 if Transaction Search was only just enabled)
   - `aws cloudwatch list-metrics --namespace ClaudeCodeAgent` lists
     `claude_code.cost.usage`
   - `aws logs describe-log-streams --log-group-name /aws/claude-agent/events`
     shows a stream named after the run

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Run succeeds, no trace anywhere, no collector lines in the log group | Image built with `AGENT_TRACING=0`, or only one of the two Claude Code switches is set | Rebuild with `AGENT_TRACING=1`; `/health` shows `tracing_enabled` |
| `collector did not open :4318 (it exited with <rc> ...)` | The collector really failed: a bad `otel-collector.yaml`, or a missing one (the core build also refuses `sigv4auth`). Its own error is on the preceding lines | Read the collector's stderr in the log group; `otel-collector.yaml` must be in the zip (`build-image.sh` checks) |
| `collector did not open :4318 (still not listening after 120s)` | Cold start slower than the budget — a very large input set competing for IO, or a smaller `MVM_MEMORY_MIB` | Rerun; if it repeats, raise `COLLECTOR_START_TIMEOUT` in `app.py` (a rebuild) rather than treating it as a crash |
| Trace exists but starts mid-run, with the first tool calls missing | An older image that waited only 20 s for the collector and then ran ahead of it | Rebuild: the wait now overlaps the input download and runs right before `claude` |
| `Exporting failed ... 403` / `AccessDenied` on `otlp_http/traces` | Execution role lacks the xray actions | `./create-roles.sh`, then rerun — no rebuild needed |
| `Exporting failed ... AccessDenied` on `awsemf` or `awscloudwatchlogs` | Execution role lacks the CloudWatch Logs actions on `/aws/claude-agent/*`. Traces are unaffected, so you get a trace and no cost data | `./create-roles.sh`, then rerun |
| `Exporting failed ... ValidationException` or `404` | Transaction Search not enabled in this region, so the OTLP endpoint rejects the write | Step 2 above, in the region the run used |
| `Exporting failed ... HTTP Status Code 400, Message=The OTLP API is supported with CloudWatch Logs as a Trace Segment Destination` on `otlp_http/traces`, and `telemetry drained: spans 0/N` | The account's trace segment destination is still `XRay`, so the OTLP endpoint refuses every span. **`Status: ACTIVE` is not the thing to check** — `Destination: XRay` with `Status: ACTIVE` reads like a healthy setting and loses every span | `aws xray get-trace-segment-destination`; if it says `XRay`, step 2 above. `agent/status.sh` reports this under `==> telemetry` without the digging, including which of step 2's calls is missing |
| `update-trace-segment-destination` itself fails: `AccessDeniedException: XRay does not have permission to call PutLogEvents on the aws/spans Log Group` | Step 2's **second** call run without its first: the destination cannot be switched until a CloudWatch Logs resource policy lets `xray.amazonaws.com` write to `aws/spans`. The error names X-Ray's own permissions, not yours, which is what makes it confusing | Run step 2 a) `logs put-resource-policy`, then retry b). Nothing needs rebuilding or rerunning in between |
| `telemetry drained` shows `spans N/N` but `aws/spans` is empty | Enabled less than ~10 minutes ago, or you are querying a different region than the run | Wait, then re-query; the region is in the run's log group name and in `_status.json` |
| `telemetry drained: ... metrics 0/0 ...` on a normal run | Metrics exporter off in that image, or the run was too short to cross one `OTEL_METRIC_EXPORT_INTERVAL` (10 s) | Check the image's `OTEL_METRICS_EXPORTER`; a run with at least one API call always produces cost datapoints |
| `get-metric-statistics` returns no datapoints although the metric is listed | It matches only a complete dimension set, and these datapoints carry 17 dimensions | Query with Metrics Insights (`get-metric-data` + a `SELECT ... WHERE` expression), or pass every dimension `list-metrics` reports |
| Namespace `ClaudeCodeAgent` exists but has no `agent.run_id` dimension | `resource_to_telemetry_conversion` disabled in `agent/otel-collector.yaml` | Re-enable it, or query by `service.name` instead and accept per-run attribution being gone |
| `the log entry's timestamp is older than 14 days or more than 2 hours in the future` | CloudWatch Logs rejects the record, not a config problem — a VM whose clock is far off, or replayed data | Check the VM's clock; this is the one error here that is not IAM |
| Events arrive, but every record is just `claude_code.user_prompt` / `claude_code.tool_result` with no content | `raw_log: true` on the `awscloudwatchlogs/events` exporter. It writes only the record's Body, and a Claude Code event's Body is its name — the prompt, `tool_name`, `duration_ms` and `prompt.id` are all attributes, and they are dropped. The content gates and the flush counters all look healthy, so nothing reports it | `raw_log: false` in `agent/otel-collector.yaml` (a rebuild). Earlier runs cannot be recovered — the attributes never left the VM |
| Query returns nothing for a run you can see in the console | Field name guessed rather than checked | `fields @message \| limit 1` and copy the real keys |
| `telemetry flush timed out after 25s; spans 0/1, metrics 0/1, logs ?/1, queued 1` | The collector accepted telemetry it could not settle — usually one of the 403s above, so it kept retrying. The line names which signal is stuck | Fix the cause; the VM still terminated, and the next run will be clean |
| Telemetry for a very fast run is missing its tail | Should not happen — `app.py` drains all three signals before `TerminateMicrovm`, waiting out the collector's batch window first. If it does, the flush logged a warning; read it | Check for `collector telemetry endpoint unreachable` on :8888 |

---

## Cost

Three signals, three line items, and they scale differently:

| Signal | Billed as | What drives it here |
| --- | --- | --- |
| Traces | Span ingestion, separate from log ingestion; Transaction Search switches all span ingestion into that mode account-wide. Indexing 1% is free and is what this document recommends — you still get every span in `aws/spans`, indexing only affects trace summaries | A few hundred spans per run, but the content gates make each one much bigger than a default span: **bytes, not span count** |
| Metrics | Custom metrics, one per unique dimension set | `agent.run_id` as a dimension means one metric stream per run. Negligible at a handful of runs, a real number if you run thousands of jobs — the knob is `resource_to_telemetry_conversion` |
| Events | CloudWatch Logs ingestion and storage | The same content gates: prompts, assistant text and tool output are the bulk |

The cheapest way to cut volume without losing the shape of a run is to drop the
content gates rather than the signals — `OTEL_LOG_TOOL_CONTENT=0` first, since
tool output is the largest of the four. `AGENT_TRACING_DETAILED=1` goes the
other way and multiplies trace volume per request.

A retention policy is worth setting on both log groups; neither has one by
default, and nothing in this project reads them after a run:

```bash
for g in /aws/claude-agent/events /aws/claude-agent/metrics; do
  aws logs put-retention-policy --log-group-name "$g" \
    --retention-in-days 14 --region "${AWS_REGION}"
done
```

---

## Where the code is

| File | Its part in this |
| --- | --- |
| `agent/Dockerfile` | Installs `otelcol-contrib` (pinned `OTELCOL_VERSION`) and bakes the `CLAUDE_CODE_*` / `OTEL_*` environment: three exporters, four content gates, the content limit, the cardinality knobs and the export intervals |
| `agent/otel-collector.yaml` | The receiver on `:4318` serving all three signals, the SigV4 signer, the three exporters (`otlp_http` for traces, `awsemf` for metrics, `awscloudwatchlogs` for events), and the Prometheus endpoint on `:8888` that the flush reads |
| `agent/app.py` | `start_collector()` at the top of a job and `wait_for_collector()` right before `claude` (the warm-up overlaps the input download), `agent_env()` stamps `agent.run_id`, `flush_telemetry()` between `_status.json` and `TerminateMicrovm`, and `/health` reports `tracing_enabled` / `telemetry_counters` |
| `agent/build-image.sh` | `AGENT_TRACING` → both switches; `AGENT_TRACING_DETAILED` → the beta pair with the endpoint pinned to the in-VM collector; ships `otel-collector.yaml` in the zip and refuses to build without it |
| `agent/test-image.sh` | Asserts the image can trace, costing no tokens |
| `agent/status.sh` | Reads the spans of a run in flight to report what the agent is doing right now, and the cost metrics to report what it has spent |
| `create-roles.sh` | The `ExportSpans` and `ExportMetricsAndEvents` statements on the execution role |

The ordering inside `app.py` is the part worth not breaking: artifacts →
`_status.json` → **flush telemetry** → `TerminateMicrovm`. The status file comes
first because it is the only thing a human is waiting for; the flush comes
before the terminate because nothing outside the VM is holding that telemetry,
and nothing will retry it.

The flush itself has one subtlety worth preserving. "Nothing queued" is not
enough to declare a signal drained: data sits in the collector's batch processor
for up to its timeout before any exporter sees it, and an exporter with no
sending queue reports no backlog while it waits — so the flush also requires
that no new telemetry has arrived for longer than that window before it trusts
an exporter that publishes no counters of its own.
