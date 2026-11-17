# Lab 11 Practical Report: CI/CD with AWS CodeBuild and AWS CodePipeline

## 1. Aim / Objective

The aim of this lab is to make the USMS enrolment service **built by a machine, not by hand**. I wrote the service's source files and build instructions (`buildspec.yml`), created a **CodeBuild** project to build it, and joined everything into a two-stage **CodePipeline** that takes a versioned source zip from S3 and produces a tested build artifact. Everything was done with the AWS CLI on Floci.

The specific objectives were to:

- Understand what **CI/CD** is and the job of S3, CodeBuild and CodePipeline.
- Create a **versioned, private S3 bucket** for pipeline artifacts.
- Write the service **source tree**, a **smoke test** and a **`buildspec.yml`** with four phases.
- Create two **least-privilege roles**, one for CodeBuild and one for CodePipeline.
- Create the CodeBuild project, run a build, and write a **local runner** for the same buildspec.
- Create a **Source → Build** pipeline and run it end to end.
- **Break the build on purpose**, find the problem and fix it.
- Save values to `configs/lab-11.env`, check the lab with a verification script, and commit.

## 2. Introduction

**CI/CD** means **Continuous Integration / Continuous Delivery**. Every change to the code goes through the same automatic steps: get the source, build it, test it, and produce an artifact that is ready to deploy. This removes "it works on my laptop" problems and makes every release repeatable.

In AWS, three services share the work:

| Service | Its job | Simple comparison |
|---|---|---|
| **Amazon S3** | Stores the versioned source zip and the build artifacts | The warehouse |
| **AWS CodeBuild** | Runs the commands in `buildspec.yml` in a build container | The factory worker |
| **AWS CodePipeline** | Joins the stages: get source → build | The conveyor belt |

`buildspec.yml` lives **inside the source code** and has four phases:

| Phase | Simple meaning |
|---|---|
| `install` | Install the tools needed |
| `pre_build` | Check things that must be right **before** building |
| `build` | Produce the output |
| `post_build` | Test the output and report |

Other key ideas:

- **Artifact:** the files the build keeps (here, the `dist/` folder).
- **S3 versioning:** every upload of the same file is kept, so old releases can always be found again.
- **Service role:** the identity a service uses. Each service gets only the permissions it needs.
- **`iam:PassRole`:** permission to give a role to a service. The pipeline may only pass the build role, and only to CodeBuild.

This lab was done on **Floci**. Floci accepts CodeBuild and CodePipeline, but it **cannot run a real build**, because the build image `aws/codebuild/standard` cannot be downloaded. So every build ends with `FAULT`. I produced the artifact with a **local runner** instead.

## 3. Use Case

**USMS use case:** the enrolment service was built by hand, so nobody could say exactly what was running or how it was made. The university wanted:

- **A repeatable build** using commands stored next to the code.
- **Checks before building**, such as a missing `VERSION` file, invalid JSON, a wrong container name or a wrong port.
- **A tested artifact** with the release number and build time stamped inside, and seven smoke tests that must pass.
- **Traceability**: each artifact records its release (`r3`, `r4`, `r5`), and every earlier source upload can still be found.
- **Least privilege**: the build may only write its own logs and the artifact bucket, and the pipeline may only start this one build project.

**Other real-world uses of CI/CD:**

- Every company that ships software often (web apps, mobile apps, APIs).
- Running tests automatically on every code change before it is merged.
- Building container images and deploying them automatically (Lab 12).

## 4. System Architecture / Design

**How it works in simple words:**

1. **Source:** I zip `labs/lab-11-cicd/app/` (with `buildspec.yml` at the root) and upload it to `s3://usms-pipeline-artifacts/source/usms-enrolment-src.zip`. Every upload creates a **new version**.
2. **Stage 1 – Source:** the pipeline reads the latest version from S3 and saves it as **`SourceOutput`**.
3. **Stage 2 – Build:** CodeBuild project **`usms-enrolment-build`** runs the four phases and uploads `dist/` as **`BuildOutput`**.
4. **Permissions:** CodePipeline uses **`usms-codepipeline-role`**, and CodeBuild uses **`usms-codebuild-role`**.
5. **On Floci:** stage 1 succeeds, stage 2 fails because the build image cannot be downloaded. The **local runner** `usms-buildspec-run.sh` runs the same phases on my machine.

| Resource | Name | Key settings |
|---|---|---|
| S3 bucket | `usms-pipeline-artifacts` | Versioning on, public access blocked |
| CodeBuild project | `usms-enrolment-build` | `aws/codebuild/standard:7.0`, 15 min timeout |
| CodeBuild role | `usms-codebuild-role` | Policy `USMSCodeBuildBase` |
| Pipeline | `usms-enrolment-pipeline` | 2 stages |
| Pipeline role | `usms-codepipeline-role` | Policy `USMSCodePipelineBase` |

## 5. Implementation Procedure

### Step 1: Start Floci

I started Floci and checked storage. `whoami.sh` showed account **000000000000**: "this is Floci, not real AWS".

![Step 1](assets/1.png)

### Step 2: Load earlier labs' env files

I loaded the env files for Labs 01–10.

![Step 2](assets/2.png)

The values this lab inherits (cluster, service, container, target group, exec role) were all set.

![Step 2 verify](assets/2.1.png)

### Step 3: Probe CI/CD support

My probe script showed that CodeBuild, CodePipeline, ECR and CodeDeploy APIs all answer, so it chose **Path A**. Later I found that builds cannot actually run, so parts of the lab followed Path B.

![Step 3](assets/3.png)

### Step 4: Create the lab folders

I created `app/src`, `app/config` and `app/tests`.

![Step 4](assets/4.png)

### Step 5: Create the artifact bucket

I created `usms-pipeline-artifacts`, turned on **versioning** and **blocked public access**.

![Step 5](assets/5.png)

Versioning is **Enabled** and the tags are set.

![Step 5 verify](assets/5.1.png)

### Step 6: Prove versioning works

I wrote two different files to the same key. S3 kept **two versions**, with only the newest marked as latest. The old one was not overwritten.

![Step 6](assets/6.png)

Then I deleted both test versions.

![Step 6 cleanup](assets/6.1.png)

### Step 7: Write the source tree

**Part 1:** `VERSION` holds `r3`, and `src/index.html` has two placeholders (`__RELEASE__` and `__BUILT_AT__`) that the build must replace.

![Step 7 part 1](assets/7.png)

**Part 2:** `config/service.json` names the container `enrolment-api` on port **80**.

![Step 7 part 2](assets/7.1.png)

**Part 3:** `tests/smoke.sh` has **seven checks**, such as "placeholders replaced" and "container name matches".

![Step 7 part 3](assets/7.2.png)

All five source files exist.

![Step 7 verify](assets/7.3.png)

### Step 8: Write buildspec.yml

I wrote `buildspec.yml` with the four phases and `artifacts.base-directory: dist`. I used a quoted heredoc, so variables like `$USMS_RELEASE` stay in the file for CodeBuild to fill in later. Each section appears exactly once.

![Step 8](assets/8.png)

### Your turn: fail the build if the port is not 80

I added a check in `pre_build` that stops the build if `config/service.json` does not say `"port": 80,`.

![Your turn 1](assets/your-turn1.png)

When I changed the port to 8080, the check printed my message and stopped with **exit code 1**. With port 80 it **PASSED**.

![Your turn 1 result](assets/your-turn1.1.png)

### Step 9: Create the CodeBuild role

**Part 1:** the trust policy allows only **`codebuild.amazonaws.com`** in this account.

![Step 9 part 1](assets/9.png)

**Part 2:** the permissions allow writing **only its own logs** and reading/writing **only the artifact bucket**.

![Step 9 part 2](assets/9.1.png)

**Part 3:** I created `usms-codebuild-role` and attached `USMSCodeBuildBase`.

![Step 9 part 3](assets/9.2.png)

![Step 9 verify](assets/9.3.png)

### Step 10: Create the CodeBuild project

I wrote the project template: source from S3, image `aws/codebuild/standard:7.0`, small instance, 15 minute timeout.

![Step 10](assets/10.png)

The project `usms-enrolment-build` was created.

![Step 10 create](assets/10.1.png)

![Step 10 verify](assets/10.2.png)

### Step 11: Package and upload the source

I wrote `usms-pack-source.sh`, which zips the folder so `buildspec.yml` is at the root. `zip` was not installed, so it used Python instead.

![Step 11 part 1](assets/11.png)

The zip has **6 files** and was uploaded as the first source version. (At first I ran it in the wrong copy of the course and got "not a directory".)

![Step 11 part 2](assets/11.1.png)

### Step 12: Run the build

`start-build` returned `usms-enrolment-build:1`.

![Step 12](assets/12.png)

The build ended with **FAULT**.

![Step 12 verify](assets/12.1.png)

### Step 13: Read the build phases and logs

The phases show the source was downloaded successfully, but none of my four phases ran. The reason was: **"pull access denied for aws/codebuild/standard"**. So my code was fine; Floci could not download the build image.

![Step 13](assets/13.png)

The log stream exists but is **empty**, because the build container never started.

![Step 13 log](assets/13.1.png)

### Step 14: The local buildspec runner

I wrote `usms-buildspec-run.sh`, which reads `buildspec.yml` and runs the four phases on my machine. All phases passed: configuration validated, **release=r3**, **all 7 smoke tests ok**, exit status **0**.

![Step 14](assets/14.png)

`build-metadata.json` shows release `r3`, and the page placeholder was replaced.

![Step 14 verify](assets/14.1.png)

I added `dist/` to `.gitignore`, so build output is never committed.

![Step 14 gitignore](assets/14.2.png)

### Step 15: Create the CodePipeline role

The pipeline policy allows three things only: use the artifact bucket, start **only** `usms-enrolment-build`, and pass **only** `usms-codebuild-role` **only** to CodeBuild. My first policy file was empty, so I rewrote it.

![Step 15 part 1](assets/15.png)

I created `usms-codepipeline-role` and attached `USMSCodePipelineBase`.

![Step 15 part 2](assets/15.1.png)

![Step 15 verify](assets/15.2.png)

### Step 16: Write the pipeline definition

`lab-11-pipeline.json` defines two stages: **Source** (S3) and **Build** (CodeBuild).

![Step 16](assets/16.png)

### Step 17: Create the pipeline

The pipeline `usms-enrolment-pipeline` was created with **2 stages**.

![Step 17](assets/17.png)

On real AWS it would start running immediately. On Floci, both stage statuses were `None`.

![Step 17 verify](assets/17.1.png)

### Step 18: Give the project to the pipeline

I changed the project's source to **`CODEPIPELINE`**, so it only builds what the pipeline gives it.

![Step 18](assets/18.png)

A one-off build with a source override still works for testing.

![Step 18 verify](assets/18.1.png)

### Step 19: Run the pipeline end to end

I changed `VERSION` to **r4** and uploaded again, creating a second version. (A pasted line broke here, so the zip was not rebuilt; I fixed this in the next step.)

![Step 19 part 1](assets/19.png)

I started the pipeline. **Source = Succeeded**, which proves the bucket, file and pipeline role are correct. **Build = Failed** because of the image problem.

![Step 19 part 2](assets/19.1.png)

There was no `BuildOutput` in S3, so I ran the local runner. The artifact shows **release r4**, proving the build used the changed file.

![Step 19 part 3](assets/19.2.png)

### Your turn: roll forward to r5

I set `VERSION` to **r5**, packed it correctly, uploaded it and started the pipeline (Source Succeeded).

![Your turn 2](assets/your-turn2.png)

The local runner built **r5**. There are now **3 source versions** (r3, r4, r5) but **0 BuildOutput** objects. A source version is created by every upload, but a BuildOutput is only created when a build **finishes successfully**, which never happens on Floci.

![Your turn 2 result](assets/your-turn2.1.png)

### Step 20: Break the build on purpose, then fix it

I changed the container name to `enrolment-api-v2` (wrong) and started the pipeline.

![Step 20 part 1](assets/20.png)

The pipeline showed **Build = Failed**.

![Step 20 diagnose](assets/20.1.png)

Reading the failed phase showed the real cause on Floci was the image pull. On real AWS it would fail in **`pre_build`** with my "wrong container" message. Lesson: **read the failing phase and its message, not just "Failed".**

![Step 20 failing phase](assets/20.2.png)

I fixed the container name, and the local build **passed again**.

![Step 20 fix](assets/20.3.png)

### Step 21: Save values and commit

I wrote `configs/lab-11.env`. My first version had Windows line endings and unexpanded commands, so I regenerated it in WSL. It has **26 exports**, all populated.

![Step 21](assets/21.png)

`git status` showed the new Lab 11 files.

![Step 21 git status](assets/21.1.png)

I committed them as `77b8954`.

![Step 21 commit](assets/21.2.png)

## 6. Verification

I ran `scripts/utilities/verify-lab-11.sh`, which checks the bucket, both roles, the CodeBuild project, the pipeline, the source files and Git hygiene. The result was **PASS=46, FAIL=0**. The script checks the stored configuration, which Floci keeps correctly; Floci only fails when it tries to *run* a build.

![Verification](assets/veri.png)

## 7. Analysis and Discussion

### 7.1 What was achieved

- A **versioned, private** artifact bucket was created and versioning was proven.
- The source tree has its own **buildspec** with checks (including my port-80 check) and **7 smoke tests**.
- Two **least-privilege roles** were created for CodeBuild and CodePipeline.
- The CodeBuild project and the **two-stage pipeline** were created, and the **Source stage succeeded** every time.
- The local runner built releases **r3, r4 and r5**, all passing every test.
- The verification passed **46 of 46** checks.

### 7.2 Observations

- **The build belongs with the code.** Changing the build is a normal, versioned change.
- **Fail early with a clear message.** `pre_build` stops bad configuration before anything is built.
- **Phases show where a problem is.** The phase table showed at once that the problem was the environment, not my code.
- **Versioning makes rollback easy.** Every old release is still in S3.
- **Least privilege can be very precise.** The pipeline can start one project and pass one role to one service.
- **A local runner is useful**, but "passed locally" is not the same as "passed in CodeBuild".
- **Floci limits.** Builds cannot run, so there is no BuildOutput and no build logs.

## 8. Reflection

### What I learned about CI/CD

Before this lab I thought "the build" was something a developer does on their own laptop. Now I see it as a **chain of evidence**: a versioned source file, a build that records which source it used, tests that must pass, and an artifact that says which release it contains. If one link is missing, nobody can be sure what is running. The most useful lesson came from the failures: the image-pull fault taught me to read the failing phase and its message instead of just "Failed".

### Challenges I faced

Several things went wrong. I first ran commands in the wrong copy of the course, my pipeline policy file was empty, and twice a pasted command broke across two lines so the packer did not run and an old zip was uploaded with no error. My `configs/lab-11.env` also had Windows line endings. I learned to read the whole output of every command, check that the file really changed (for example by checking the release inside the artifact), and keep everything in one folder.

## 9. Conclusion

In this lab I built the CI/CD foundation for the USMS enrolment service. All objectives were achieved: I created a versioned artifact bucket, wrote the source tree with a four-phase buildspec and smoke tests, created two least-privilege roles, the CodeBuild project and a two-stage pipeline, and broke and fixed the build on purpose. The Source stage always succeeded; the Build stage could not run on Floci, so I used the local runner, which built r3, r4 and r5 successfully. The verification passed **46 of 46** checks and the lab was committed.

The key concepts I learned are the CI/CD flow, buildspec phases, artifacts, S3 versioning, service roles and scoped `iam:PassRole`. CI/CD is important because it makes every release repeatable and tested, and this lab prepares the pipeline for the Deploy stage in Lab 12.
