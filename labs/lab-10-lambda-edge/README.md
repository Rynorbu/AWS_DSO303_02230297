# Lab 10 Practical Report: Edge Functions with AWS Lambda and Lambda@Edge

## 1. Aim / Objective

The aim of this lab is to protect and speed up the delivery of USMS student transcripts by running small pieces of code **at the edge** (Lambda@Edge in front of CloudFront) and in a **region** (a normal Lambda triggered by S3). I wrote three functions, tested them with realistic events, attached the edge functions to a CloudFront distribution and connected an S3 bucket notification. Everything was done with the AWS CLI on Floci.

The specific objectives were to:

- Understand the difference between an **edge function** and a **regional function**.
- Let the Lab 01 role `usms-lambda-exec-role` also trust **`edgelambda.amazonaws.com`**.
- Write a **viewer-request** function that lower-cases the URL and **blocks** transcript requests with no student header.
- Write an **origin-response** function that adds **security headers** and a **cache-control** header.
- **Publish numbered versions**, check them against the Lambda@Edge rules, and attach them to a CloudFront distribution.
- Build a regional **transcript notifier** that S3 triggers when a new transcript `.json` file is uploaded.
- Prove everything survives a restart, save values to `configs/lab-10.env`, and check the lab with a verification script.

## 2. Introduction

**AWS Lambda** runs code without servers: you upload a function and AWS runs it when an event happens. You only pay while the code runs.

**Amazon CloudFront** is a **CDN (content delivery network)**. It keeps copies (a cache) of files in locations around the world, so users download them from somewhere close.

**Lambda@Edge** runs a Lambda function inside CloudFront, close to the user. CloudFront has four places where a function can run:

| Trigger point | When it runs | Used in this lab for |
|---|---|---|
| **viewer-request** | Every request, **before** the cache | Login check and URL clean-up |
| origin-request | Only on a cache miss | Not used |
| **origin-response** | After the origin (S3) replies, **before** caching | Security and cache headers |
| viewer-response | Every response, before it goes back | Not used |

Edge and regional functions follow different rules:

| | Edge function | Regional function |
|---|---|---|
| Where it runs | CloudFront locations worldwide | One region (`us-east-1`) |
| Environment variables | **Not allowed** | Allowed |
| Memory / timeout | Max **128 MB / 5 s** (viewer triggers) | Up to 10 GB / 15 min |
| Version | Must be a **numbered version** (`:1`), not `$LATEST` | Can use an alias like `live` |
| Role trusts | `lambda` **and** `edgelambda` | `lambda` only |

Two more ideas were important:

- **Role vs resource policy:** the role says what the function may **do**; the resource policy says who may **call** it (here, S3).
- **Request vs response:** a viewer-request function returns the **request** to continue, or a **response** (like 403) to stop it there.

This lab was done on **Floci**. Floci stores the CloudFront distribution but does not run a real edge network, so I tested the edge chain by calling the functions directly and with a simulator script.

## 3. Use Case

**USMS use case:** students download transcripts from CloudFront, which serves them from the `usms-student-data` bucket. The university wanted:

- **No anonymous downloads.** A request to `/transcripts/` without the `X-USMS-Student` header gets a **403 at the edge**, so the bucket is never contacted.
- **One cache copy per transcript.** `STU-00417.json` and `stu-00417.json` are treated as the same file by lower-casing the URL.
- **Safe browser behaviour.** Every transcript gets security headers (HSTS, `nosniff`, `X-Frame-Options`, referrer policy) and a cache time.
- **A notification on upload.** Only `.json` files under `transcripts/` trigger the notifier.

**Other real-world uses:**

- Checking login tokens at the edge before content is served.
- Redirecting users by country or device.
- Adding security headers to websites.
- Processing images or files as soon as they are uploaded to S3.

## 4. System Architecture / Design

**How it works in simple words:**

1. **Download path:** a student's request reaches CloudFront → **`usms-edge-viewer-request:1`** lower-cases the URL and checks the student header. No header → **403**, stop. Header present → continue → CloudFront gets the file from **`usms-student-data`** → **`usms-edge-origin-response:1`** adds the security and cache headers → the response is cached and returned.
2. **Upload path:** a file is uploaded to the bucket → if it starts with `transcripts/` **and** ends with `.json`, S3 calls **`usms-transcript-notifier:live`** → it writes a `USMS_NOTIFY` line to CloudWatch Logs.
3. **Permissions:** all three functions use `usms-lambda-exec-role`. S3 may call the notifier only because of a **resource policy** limited to the `usms-student-data` bucket.

| Function | Runtime | Memory | Timeout | Trigger |
|---|---|---|---|---|
| `usms-edge-viewer-request` | nodejs20.x | 128 MB | 5 s | CloudFront viewer-request |
| `usms-edge-origin-response` | nodejs20.x | 128 MB | 5 s | CloudFront origin-response |
| `usms-transcript-notifier` | python3.12 | 256 MB | 30 s | S3 upload, alias `live` |

## 5. Implementation Procedure

### Step 1: Start the environment

I started Floci in **hybrid** storage mode. All storage checks were **[ok]**.

![Step 1](assets/1.png)

### Step 2: Load the env files and confirm my identity

I loaded `course.env` and Labs 01–09. The account is **000000000000**, so this is Floci.

![Step 2](assets/2.png)

The bucket name, Lambda role and account ID were all set.

![Step 2 verify](assets/2.1.png)

### Step 3: Create the lab folders

I created `edge-viewer-request/`, `edge-origin-response/` and `transcript-notifier/`.

![Step 3](assets/3.png)

![Step 3 verify](assets/3.1.png)

### Step 4: Find out what Floci supports

Lambda, S3, CloudWatch Logs and **CloudFront** were all **SUPPORTED**. `get-role` showed unsupported only because the probe passed a full ARN instead of a role name.

![Step 4](assets/4.png)

### Step 5: Create the origin bucket

I created `usms-student-data` (only if missing) and tagged it. Lab 01's `USMSStudentDataReadWrite` policy now points at a bucket that really exists.

![Step 5](assets/5.png)

![Step 5 verify](assets/5.1.png)

### Step 6: Let the role trust the edge

**Part 1:** My first `get-role` failed with `NoSuchEntity`, because my variable held the **ARN** but `--role-name` needs the plain name. I fixed it with `${USMS_ROLE_LAMBDA##*/}`. The role trusted only `lambda.amazonaws.com`.

![Step 6 part 1](assets/6.png)

**Part 2:** I wrote a trust policy with **two** services: `lambda.amazonaws.com` and `edgelambda.amazonaws.com`.

![Step 6 part 2](assets/6.1.png)

**Part 3:** I updated the role's trust policy.

![Step 6 part 3](assets/6.2.png)

**Verify:** the role now trusts 2 services. Its permissions did not change.

![Step 6 verify](assets/6.3.png)

### Step 7: Write the viewer-request function

`index.mjs` does four things: lower-cases the URL, lets non-transcript requests pass, returns a **403** when the `x-usms-student` header is missing, and otherwise adds `x-usms-edge: viewer-request-allow;student=<id>`.

![Step 7](assets/7.png)

**Verify:** the file has 55 lines and the JavaScript `${studentId...}` was kept, because I used a quoted heredoc.

![Step 7 verify](assets/7.1.png)

### Step 8: Package and create the function

My first zip went to the wrong folder because `COURSE_ROOT` pointed at another copy of the course. I fixed it and rebuilt the zip.

![Step 8 part 1](assets/8.png)

I created `usms-edge-viewer-request` with **nodejs20.x**, **128 MB** and **5 s**.

![Step 8 part 2](assets/8.1.png)

The function is **Active**.

![Step 8 verify](assets/8.2.png)

### Step 9: Test with a real CloudFront event

I wrote a CloudFront test event for `GET /transcripts/2026/STU-00417.json` with the student header.

![Step 9 part 1](assets/9.png)

The function returned the **request**, with the URL lower-cased and the `x-usms-edge` header added.

![Step 9 part 2](assets/9.1.png)

The check printed **"viewer-request allow path: correct"**.

![Step 9 verify](assets/9.2.png)

### Your turn: prove the deny path

I made the same event **without** the student header.

![Your turn 1](assets/your_turn1.png)

The invoke succeeded (Status 200): the function did not crash, it **made a decision**.

![Your turn 1 invoke](assets/your_turn1.1.png)

The result is a **response**, not a request: status **403 Forbidden**, header `viewer-request-deny`, a JSON message, and no `uri`. So an anonymous request is stopped at the edge.

![Your turn 1 result](assets/your_turn1.2.png)

### Step 10: Read the function's logs

On Floci, `--log-type Tail` returned **`None`**, and decoding it printed garbage characters. The log group exists but has **0 stored bytes**, so Floci does not save these logs.

![Step 10](assets/10.png)

![Step 10 verify](assets/10.1.png)

### Step 11: Publish a version

I published **version 1**. CloudFront needs a numbered version because the code copied to every edge location must never change, while `$LATEST` can change at any time.

![Step 11](assets/11.png)

The check printed **"ARN is version-qualified - the edge would accept this"**.

![Step 11 verify](assets/11.1.png)

### Step 12: Write and deploy the origin-response function

This function sets four **security headers**, a **cache-control** header (5 minutes in the browser, 1 hour in CloudFront) and a chain marker.

![Step 12 part 1](assets/12.png)

I created `usms-edge-origin-response` with the same edge-safe settings.

![Step 12 part 2](assets/12.1.png)

![Step 12 verify](assets/12.2.png)

### Step 13: Test the origin-response function and publish it

I wrote an event that includes the request and the S3 response.

![Step 13 part 1](assets/13.png)

The function returned **200 OK** with the new headers. I published **version 1**.

![Step 13 part 2](assets/13.1.png)

The check printed **"4 security headers + cache-control + chain marker"**. The chain header shows both functions ran in order.

![Step 13 verify](assets/13.2.png)

### Step 14: Check the Lambda@Edge rules

I added environment variables to the viewer function on purpose. **Floci accepted it**, but real CloudFront would refuse. The emulator does not catch this mistake.

![Step 14 part 1](assets/14.png)

I removed them and checked both functions: no environment variables, 128 MB, 5 s, nodejs20.x, no VPC and a published version. All **ok**.

![Step 14 part 2](assets/14.1.png)

**0 failures — both functions are edge-eligible.**

![Step 14 verify](assets/14.2.png)

### Step 15: Attach both functions to CloudFront

I wrote a distribution config with the S3 origin and two function associations using **version 1** ARNs.

![Step 15 part 1](assets/15.png)

Floci created distribution **`EHPVYOGADVTSYD`**.

![Step 15 Path A](assets/15.1.png)

It is **Enabled** and **Deployed**, with viewer-request and origin-response associations.

![Step 15 verify](assets/15.2.png)

A structural check also passed all **11** rules (one origin, version-qualified ARNs, HTTPS only, no cookies forwarded, etc.).

![Step 15 Path B](assets/15.3.png)

### Step 16: Run the edge chain end to end

I wrote `usms-edge-simulate.sh`, which runs viewer-request → fake S3 → origin-response, just like CloudFront.

![Step 16 part 1](assets/16.png)

| Run | Decision | Status |
|---|---|---|
| With student header | **allow** (all three stages) | **200** |
| Without header | **deny** (viewer-request only) | **403** |

In the deny run it printed **"DENY - the origin is never contacted"**. This is the main proof of the lab.

![Step 16 part 2](assets/16.1.png)

![Step 16 verify](assets/16.2.png)

### Step 17: Write the regional notifier

`notifier.py` reads each S3 record, skips keys outside `transcripts/`, checks it can read the object, and prints a `USMS_NOTIFY` line.

![Step 17](assets/17.png)

It uses two environment variables, which is fine for a **regional** function.

![Step 17 verify](assets/17.1.png)

### Step 18: Create the notifier with an alias

I created `usms-transcript-notifier` with **python3.12**, **256 MB** and **30 s**.

![Step 18 part 1](assets/18.png)

I published **version 1** and created the alias **`live`** pointing at it.

![Step 18 part 2](assets/18.1.png)

![Step 18 verify](assets/18.2.png)

### Step 19: Let S3 call the function

I added a **resource policy** that lets `s3.amazonaws.com` call the `live` alias, only when the source is **`arn:aws:s3:::usms-student-data`**. Without this condition, any bucket could trigger my function (the confused deputy problem from Lab 09).

![Step 19](assets/19.png)

The check printed **"scoped to one bucket in one account"**.

![Step 19 verify](assets/19.1.png)

### Step 20: Connect the bucket notification and fire it

I set a notification for `s3:ObjectCreated:*` with prefix **`transcripts/`** and suffix **`.json`**.

![Step 20 part 1](assets/20.png)

I uploaded a test transcript file.

![Step 20 part 2](assets/20.1.png)

### Step 21: Prove the notifier ran

At first the log search returned nothing.

![Step 21 part 1](assets/21.png)

I also invoked the `live` alias with a test S3 event, and it returned `{"processed": 1, ...}`.

![Step 21 part 2](assets/21.1.png)

### Your turn: prove the notification filter

I uploaded two files that should **not** trigger the notifier: `notes/ignore-me.json` (wrong prefix) and `transcripts/evidence/ignore-me.txt` (wrong suffix). The logs show a `USMS_NOTIFY` line for the real `.json` transcript upload, but **none** for the two ignored files. S3 uses **AND** for the rules, so a file must match both prefix and suffix.

![Your turn 2](assets/your_turn2.png)

### Step 22: Restart Floci and read everything back

I saved an inventory of all functions, versions, the alias, the objects and the notification.

![Step 22 part 1](assets/22.png)

I restarted Floci.

![Step 22 part 2](assets/22.1.png)

The before and after inventories were **IDENTICAL**.

![Step 22 part 3](assets/22.2.png)

I also ran the simulator again, and the functions still **worked** (allow, 200, all headers).

![Step 22 verify](assets/22.3.png)

### Step 23: Write configs/lab-10.env

I wrote `configs/lab-10.env` with the function names, ARNs, versions, alias, notification and CloudFront ID. It has no secrets.

![Step 23](assets/23.png)

**25 exports**, all populated.

![Step 23 verify](assets/23.1.png)

### Step 24: Commit

`git status` showed the new Lab 10 files, and the zip and trace files under `outputs/` are ignored.

![Step 24 part 1](assets/24.png)

The commit failed because `verify-lab-10.sh` did not exist yet, so nothing was staged.

![Step 24 part 2](assets/24.1.png)

The last commit is still Lab 09; the Lab 10 commit is made after the verify script exists.

![Step 24 verify](assets/24.2.png)

## 6. Verification

I ran `scripts/utilities/verify-lab-10.sh`, which checks the role, both edge functions, the notifier, the S3 notification, CloudFront and Git hygiene. The result was **PASS=45, FAIL=6**.

The passes include the notifier and its `live` alias, the S3 notification filter, the CloudFront associations with version-qualified ARNs, the simulator trace and no secrets in Git. The two visible failures are about the resource policy: the script reads it without the `live` qualifier, but I attached it to the alias (and Step 19 showed it is correct there).

![Verification](assets/veri.png)

## 7. Analysis and Discussion

### 7.1 What was achieved

- `usms-lambda-exec-role` now trusts the edge, without changing its permissions.
- The **viewer-request** function blocks anonymous transcript requests with a **403 at the edge**.
- The **origin-response** function adds four security headers and cache-control.
- Both functions passed the edge rules, were published as **version 1** and attached to CloudFront distribution `EHPVYOGADVTSYD`.
- The **notifier** runs only for `transcripts/*.json` uploads, through a bucket-limited resource policy.
- Everything survived a restart, and the verification passed **45 of 51** checks.

### 7.2 Observations

- **Deny early, deny cheap.** An anonymous request costs one small function call and never touches the bucket.
- **Lower-casing the URL improves caching.** One transcript is stored once, not twice.
- **Headers added before caching are paid for once.** Every later cache hit gets them for free.
- **The edge needs frozen code.** That is why only numbered versions are accepted.
- **Edge and regional rules are different.** The notifier can use environment variables and more memory; edge functions cannot.
- **Floci accepts things AWS would refuse.** My own eligibility check caught the environment variables, not the emulator.
- **Floci limits.** Tail logs return `None` and edge log groups stay empty.

## 8. Reflection

### What I learned about edge functions

Before this lab I thought Lambda was just "code that runs in a region". Now I see that the same service can run in two very different places. At the edge, the function is in the path of every request, so it has to be tiny, fast and frozen. In a region, it reacts to events and can be bigger. Choosing the trigger point is the real design decision: viewer-request for "should this request happen at all", and origin-response for "what should be stored in the cache". The most useful moment was the deny test: the invoke succeeded (Status 200), but the student got a 403, because the function decides by what it returns.

### Challenges I faced

Two of my problems came from variables holding something different from what I expected. `USMS_ROLE_LAMBDA` held an ARN instead of a name, so `get-role` failed, and `COURSE_ROOT` pointed at another copy of the course, so my zip file was "not found". I learned to print a variable before using it. I also ran the commit before the verify script existed, so Git added nothing.

## 9. Conclusion

In this lab I added edge processing to the USMS transcript service. All objectives were achieved: I gave the Lambda role the edge principal, built a viewer-request function that blocks anonymous requests and cleans the URL, built an origin-response function that adds security and cache headers, published both as version 1 and attached them to a CloudFront distribution. I also built a regional notifier triggered only by transcript `.json` uploads. Everything survived a restart, and the verification passed **45 of 51** checks.

The key concepts I learned are the four CloudFront trigger points, the differences between edge and regional functions, why the edge needs numbered versions, and the difference between a role and a resource policy. Edge functions are important because they make websites faster and safer by handling requests close to the user, before they reach the server.
