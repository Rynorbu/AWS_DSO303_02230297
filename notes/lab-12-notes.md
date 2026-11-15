# Lab 12 notes

## Your turn: USMSCodePipelineBase v2, written before reading Step 15

My draft is in `notes/lab-12-my-pipeline-policy.json`. It has five statements: the three
v1 statements copied unchanged, plus one for each of the two new capabilities.

| # | Sid | Matches Step 15? |
|---|-----|------------------|
| 1 | ReadAndWriteTheArtifactStore | yes, unchanged from v1 |
| 2 | StartAndWatchTheEnrolmentBuildOnly | yes, unchanged from v1 |
| 3 | PassTheBuildRoleAndOnlyToCodeBuild | yes, unchanged from v1 |
| 4 | DeployTheEnrolmentService (all ECS calls, `Resource: "*"`) | **no** |
| 5 | PassTheTwoEcsRolesAndOnlyToEcsTasks | **no**, the shape matches, but Step 15 has it as its sixth statement because it splits the ECS calls into two |

**The difference is in the ECS calls.** I put all four deploy calls in one statement
(`DescribeTaskDefinition`, `RegisterTaskDefinition`, `DescribeServices`, `UpdateService`).
`RegisterTaskDefinition` and `DescribeTaskDefinition` don't support resource-level
permissions, so that statement has to use `Resource: "*"`. That gives the pipeline
`ecs:UpdateService` on **every** service in the account.

Step 15 splits it into two statements:
- `DeployToTheEnrolmentServiceOnly`: `DescribeServices` and `UpdateService`, scoped to
  `service/usms-ecs-cluster/usms-enrolment-svc`.
- `ReadAndRegisterTaskDefinitions`: the task-definition calls (plus `ListTaskDefinitions`)
  on `"*"`, because they can't be scoped.

**Why:** only the actions that really can't be scoped should go on `"*"`. If you mix scopable and
unscopable actions in one statement, everything gets widened to the weakest level. So Step 15
has six statements and my draft has five. The PassRole statement is the same in both: the two
ECS roles only, and only to `ecs-tasks.amazonaws.com`, modelled on v1's CodeBuild PassRole.

## Your turn: Deploy reading SourceOutput instead of BuildOutput

From `templates/lab-12-pipeline.json`:

| Stage | Action | Input | Output |
|---|---|---|---|
| Source | FetchSource | none | SourceOutput |
| Build | BuildArtifact | SourceOutput | BuildOutput |
| Deploy | DeployToECS | BuildOutput | none (`FileName: imagedefinitions.json`) |

- The ECS deploy action opens its input artifact and looks for `imagedefinitions.json`
  **at the root of that archive**.
- **SourceOutput** is the committed source tree (`VERSION`, `buildspec.yml`, `Dockerfile`,
  `config/`, `src/`, `tests/`). `imagedefinitions.json` isn't in it. The buildspec generates it
  during the build phase into `dist/`, and `dist/` isn't committed.
- **BuildOutput** is created with `base-directory: dist` and `files: '**/*'`, so the
  *contents* of `dist/` are at the root of the zip. That's why `imagedefinitions.json`
  sits at the root, which is exactly where the deploy action looks.

**What would happen:** Source and Build would both succeed, because Build still reads
SourceOutput and still produces a correct BuildOutput that nothing uses. The **Deploy** stage
would fail because it can't find `imagedefinitions.json` in the source archive, and the
service would stay on its current task definition.

**Why this is misleading:** the error shows up in Deploy, but nothing is wrong with the ECS
service, the task definition or the IAM policy. The mistake is in the artifact wiring, a single
`inputArtifacts` name in the pipeline document. Build looks healthy, so it isn't the first place
anyone checks. The way to debug it is to trace which artifact the failing action consumes and
check that the file it names is at that artifact's root.
