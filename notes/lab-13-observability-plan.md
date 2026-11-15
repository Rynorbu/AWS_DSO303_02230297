# USMS Observability Plan

**Scope:** transcript delivery (upload → `usms-transcript-notifier` → student notification) and the services it touches. **Author's position:** this is a plan for a colleague to implement, written after Lab 13. Where a number has no measured source, I say so.

## The four complaints

| # | Complaint | Right layer | Why not the other two |
|---|---|---|---|
| A | A six-hour delivery outage was noticed by students, not by us | **Metrics** (+ alarm) | Logs only help someone who is already looking; nobody was. Traces describe requests that *happened*: during a silent outage there are no requests to trace. Only a metric alarm watching for an **absence** fires on its own. |
| B | We could not tell which layer failed (S3, Lambda, notification channel) | **Traces** | A metric says "slow" or "failing" for the whole function; logs from each service are separate and must be joined by hand. A trace shows the S3 call, the metric publish and the notify call of one request, with their timings, under one id. |
| C | An auditor asked who downloaded a transcript in March, and we could not answer | **Logs** (an audit log group) | Metrics are aggregates and have no "who". Traces are sampled (10% after the reservoir in Lab 13) and kept for a short time, so the one request an auditor asks about is probably not there. Only a complete, retained log answers "who, what, when". |
| D | Monitoring costs more than the service it monitors | **Metrics and logs** (volume and cardinality) | Traces are already sampled and cheap by design; the cost driver is log ingestion volume and the number of distinct custom metrics (each dimension combination is billed as its own metric). |

## Log group taxonomy and retention

| Log group | Contents | Retention | Who may read |
|---|---|---|---|
| `/usms/central/application` | `USMS_EVENT` lines from every app | 30 days | platform team |
| `/usms/ecs/enrolment` | enrolment service | 30 days | platform team |
| `/aws/lambda/usms-transcript-notifier` | notifier stdout, `USMS_NOTIFY`, `USMS_SUMMARY` | 14 days | platform team |
| `/aws/lambda/usms-edge-*` | Lambda@Edge functions | 14 days | platform team |
| `/usms/audit/transcript-access` (**new, audit-only**) | one structured line per transcript read or download: who, which key, when, from where | **400 days** | registrar and auditors only, through a separate IAM role; the platform roles may **write** but not read it |
| `/usms/test/*` (**new**) | scratch and test streams | **1 day** | anyone on the team |

- **Longest (audit, 400 days):** the complaint asks about "March", so the retention must cover at least a full academic year plus the time it takes for a question to reach us. 400 days is my assumption, not a university rule; **before committing, ask the registrar what the actual record-keeping requirement is**, because it may be longer, in which case the audit trail should go to S3 instead of staying in CloudWatch Logs.
- **Shortest (test, 1 day):** in Lab 13 my own scratch streams in the central group doubled `CentralErrorCount` and the faculty totals. Test data needs its own group, and nobody needs it tomorrow.
- **Why the application groups are not longer:** debug logs older than 30 days are almost never read, but are paid for every month. Anything that must be kept longer belongs in the audit group, not here.

## SLIs for transcript delivery

| SLI | Definition | Target | Alarm or graph? |
|---|---|---|---|
| **Delivery freshness** | minutes since the last successful notification (`NotifyCount` > 0) during working hours | never more than 15 minutes | **Alarm** (`usms-notify-silence`) |
| **Notification latency** | p99 (or Maximum) of `TranscriptLagSeconds` per 5 minutes | ≤ 2 s for 99% of 5-minute windows | **Alarm** (`usms-transcript-lag-high`) |
| **Success ratio** | `transcript.processed` / (`processed` + `failed`) per day | ≥ 99.5% | **Graph only** |

The targets are my starting assumptions, not measurements: the 2 s comes from the Lab 13 alarm, and my only observed latencies are the emitter's synthetic values (0.37–3.10 s). **Measure a week of real `TranscriptLagSeconds` before fixing the target.**

The success ratio is not alarmed because a single failure in a quiet hour would swing a ratio wildly and page someone for nothing. An un-alarmed SLI is not wasted: it is what the weekly review looks at, it shows slow decline that no single-window alarm would catch, and it is the evidence for whether the targets above are the right ones.

## Alarms and missing-data policies

| Alarm | Watches | Missing data | Pages? |
|---|---|---|---|
| `usms-notify-silence` | `NotifyCount` Sum < 1 for 3 × 5 min | **breaching** | through the composite |
| `usms-transcript-lag-high` | `TranscriptLagSeconds` Maximum > 2 s, 2 of 3 min | **notBreaching** | through the composite |
| `usms-transcript-pipeline-down` | composite: lag-high OR notify-silence | n/a (composite) | **yes, the only one that pages** |
| `usms-central-errors-high` (new) | `CentralErrorCount` Sum > 5 per 5 min, using the pattern `"transcript.failed"`, not bare `ERROR` | **notBreaching** | ticket only |

**The one that would have caught the six-hour outage is `usms-notify-silence`.** During an outage nothing is processed, so no latency values are published and no error lines are written. A **value** threshold such as "latency > 2 s" or "errors > 5" compares numbers that do not exist; with `notBreaching` it stays OK, and with no policy it goes to `INSUFFICIENT_DATA`, which nobody is paged for. Only an alarm that treats **missing data as breaching** turns "nothing happened" into an incident.

One caveat to verify before relying on it: at night or in holidays there are genuinely no uploads, so this alarm will fire on silence that is normal. Measure the real overnight volume first, and if it is zero, either suppress the alarm outside working hours or send a synthetic upload every 10 minutes (a canary) so silence always means failure.

## Cost, in order of magnitude

Prices are the CloudWatch and X-Ray list prices for us-east-1 as I understand them from the AWS pricing pages; **they must be re-checked on the pricing page before this plan is approved.** Volumes are my assumptions.

| Item | Assumption | Rough monthly cost |
|---|---|---|
| Custom metrics | about 10 metric series (see cardinality below) at roughly $0.30 per metric | a few dollars |
| Alarms | 4 standard alarms at roughly $0.10 each | under a dollar |
| Log ingestion | assume 5 GB/month across USMS groups at roughly $0.50/GB | a few dollars |
| Log storage | 30-day retention keeps stored volume near one month's ingestion | well under a dollar |
| Dashboards | 1 dashboard (the first few are free) | $0–3 |
| X-Ray | at 10% sampling, well inside the free tier at USMS volume | ~$0 |

So the whole plan is in the **tens of dollars per month**. If it costs more than the service, the cause is almost certainly one of these two, and they are the two changes with the largest effect:

1. **Retention on every log group.** A group with no retention grows forever; five of seven groups were on never-expire at the start of Lab 13.
2. **Dimension cardinality.** Every distinct combination of dimension values is a separately billed metric. One high-cardinality dimension (for example `StudentId`) would turn ~10 metrics into tens of thousands.

**Cardinality of every proposed dimension:**

| Dimension | Values | Cardinality |
|---|---|---|
| `Faculty` | science, engineering, … | ~6 (the number of faculties; verify with the registrar) |
| `Stage` | notify, origin | 2 |
| `StudentId`, transcript key, trace id | | **not allowed as dimensions**: unbounded. They belong in logs and trace annotations. |

## What I would not build yet

**Per-student or per-transcript metrics** (for example `DeliveryLatency` with a `StudentId` dimension). They would answer complaint C in a dashboard, but they create one billed metric per student, and the audit log group answers the same question for almost nothing.

**What would change my mind:** evidence that the audit log cannot answer the questions fast enough, for example the registrar needing a live view of individual delivery times, measured as repeated requests that a Logs query could not answer within the time they need. Until that is observed, building it would be cost without a user.
