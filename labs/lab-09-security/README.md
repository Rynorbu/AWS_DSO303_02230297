# Lab 09 Practical Report: Securing the USMS Application with IAM Roles and Security Groups

## 1. Aim / Objective

The aim of this lab is to **review and tighten the security** of everything built in Labs 01–08. Security was checked on two axes: **who can call what** (IAM) and **what can reach what** (security groups and routes). Instead of building new services, I audited the existing ones with read-only scripts, fixed the findings, and proved that the fixes survive a restart without breaking earlier labs. Everything was done with the AWS CLI on Floci.

The specific objectives were to:

- Make an **inventory** of every role, user and policy, and build **audit scripts** for IAM and security groups.
- Create a **read-only** policy and role for reading transcripts.
- Fix the **confused deputy** problem on the ECS task role's trust policy.
- Limit **`iam:PassRole`** and use a **permissions boundary** and a **session policy**.
- **Rotate an access key** with no downtime, and require **IMDSv2** on the web server.
- Write **egress rules** on three security groups and move SSH to a **bastion group**.
- Build a **reachability matrix**, prove the database is not reachable from the internet, and check the lab with a verification script.

## 2. Introduction

**Cloud security** in AWS has two separate questions:

1. **IAM (identity):** Is this user or role *allowed* to call this API?
2. **Network:** Can this server *reach* that server on this port?

Both must say yes. A good troubleshooting rule is: **an error message means IAM, a hang means the network.**

An AWS request is allowed only when every layer allows it, and an **explicit Deny always wins**:

| Order | Layer | Effect |
|---|---|---|
| 1 | Explicit `Deny` anywhere | Denied, final |
| 2 | **Permissions boundary** | Must allow (a ceiling, grants nothing) |
| 3 | **Session policy** | Must allow (a ceiling for one session) |
| 4 | **Identity policy** | Allows |
| 5 | Default | Denied |

The main ideas used in this lab:

| Concept | Simple meaning |
|---|---|
| **Trust policy** | Decides **who may become** a role |
| **Identity policy** | Decides **what the role may do** |
| **Confused deputy** | A service like `ecs-tasks.amazonaws.com` works for many customers. Without `aws:SourceAccount` / `aws:SourceArn`, another account could use my role. |
| **`iam:PassRole`** | Giving a role to a service. If it is not limited, a user could pass an admin role to EC2 and become admin. |
| **Permissions boundary** | A ceiling. Real permissions are what both the boundary and the identity policy allow. |
| **Egress rule** | Limits what a server can **send out**, so a hacked server cannot leak data anywhere. |
| **IMDSv2** | The instance metadata service needs a token, which stops many credential-stealing attacks. |

**Important:** Floci **does not enforce** IAM or security groups. It stores and returns them, so every proof in this lab is made by **reading the configuration back**.

## 3. Use Case

**USMS use case:** USMS stores student transcripts in S3, runs the enrolment service on ECS behind an ALB, and has a database in a private subnet. A security review asked for:

- A **reporting job** that can only **read** transcripts, never write or delete them.
- ECS task roles that only **this account's** tasks can use.
- A **deploy role** that can only pass the three ECS roles, only to ECS, never to EC2.
- Developer access keys that are **rotated** without downtime.
- The web server's metadata protected with **IMDSv2**.
- The ALB may only talk to the enrolment tasks, the tasks may only make HTTPS calls, the database may only fetch updates, and SSH must come from the **bastion** only.

**Other real-world uses:**

- Banks and hospitals running regular IAM audits for compliance.
- Companies rotating keys automatically every 90 days.
- Limiting outbound traffic so a hacked server cannot send data to an attacker.

## 4. System Architecture / Design

**How it works in simple words:**

1. **Network:** the internet can only reach the ALB (ports 80 and 443). The ALB may only send port 80 to the enrolment tasks. The tasks may only send HTTPS (443) out. The database only accepts port 5432 from the app tier and may only send HTTPS out through the NAT gateway. SSH to the app tier should come only from the bastion.
2. **IAM:** a task gets permissions only if the **trust policy** lets ECS (in this account) assume the role, **and** the **identity policy** allows the action, **and** no boundary, session policy or Deny blocks it.
3. **Audit scripts** (`usms-iam-audit.sh`, `usms-sg-audit.sh`, `usms-reachability-matrix.sh`) only read the configuration and print HIGH / MED / LOW findings.

## 5. Implementation Procedure

### Step 1: Resume the environment

I started Floci (hybrid mode) and loaded `course.env` and Labs 01–06. The account is **000000000000**, and all 17 values (users, VPC, security groups, S3 endpoint and instances) were filled in.

![Step 1](assets/1.png)

### Step 2: Record the security baseline

Before changing anything, I saved the results of the Lab 02–06 verify scripts. Lab 02 and 03 already had 2 failures each, and Lab 04 had **39/0**. These are the numbers I must not make worse.

![Step 2](assets/2.png)

### Step 3: Probe what Floci supports

Most IAM and EC2 read and write calls were **SUPPORTED**, including trust policy updates, permissions boundaries, policy simulation, access keys, security group rules, prefix lists and metadata options. The credential report was not available. Floci stores everything but enforces nothing.

![Step 3](assets/3.png)

### Step 4: Inventory every identity

There are **9 roles**, **5 users** (only 2 with an access key) and **11 customer-managed policies**. `USMSStudentDataReadWrite` is attached to **3** roles, and three policies are attached to nothing.

![Step 4 inventory](assets/4.png)

A Python script saved the full inventory to JSON. **No role** has a permissions boundary yet.

![Step 4 identity inventory](assets/4.1.png)

### Step 5: Build the IAM audit script

`usms-iam-audit.sh` checks every role for wildcard actions, wildcard resources, unlimited `iam:PassRole` and service trusts with no condition. The result was **HIGH=7, MED=31** for 9 roles:

- **HIGH:** several roles trust a service (`ecs-tasks`, `ec2`) with **no condition** (confused deputy).
- **MED:** some policies use `Resource "*"` on actions that change things, and no role has a boundary.

![Step 5 audit](assets/5.png)

The script exits with code **1** when there is a HIGH finding, so it could fail a CI pipeline.

![Step 5 exit code](assets/5.1.png)

### Step 6: Read the transcripts policy

`USMSStudentDataReadWrite` allows read, **write and delete** on transcripts. A reporting job only needs to read, so write and delete would be dangerous extra permissions. That is why I made a separate read-only policy.

![Step 6 policy](assets/6.png)

The bucket does not exist yet (**404**); Lab 10 creates it. A policy can name a bucket before it exists.

![Step 6 head-bucket](assets/6.1.png)

### Step 7: Create the read-only role and fix the confused deputy

**Part 1:** I wrote a read-only policy with three statements: list the bucket, read objects, and an **explicit Deny** on put, delete and changing the bucket policy.

![Step 7 RO policy](assets/7.png)

I created it as **`USMSStudentDataReadOnly`**.

![Step 7 create policy](assets/7.1.png)

**Part 2:** I wrote a scoped trust policy for `ecs-tasks.amazonaws.com` with two conditions: `aws:SourceAccount = 000000000000` and `aws:SourceArn` must be an ECS ARN in this account.

![Step 7 scoped trust](assets/7.2.png)

**Part 3:** I created **`usms-transcripts-reader-role`** with this trust and the read-only policy. Then I saved the old trust of `usms-ecs-task-role` (as an undo) and updated it to the scoped trust. I did not remove its read-write policy, because Lab 10 needs it.

![Step 7 reader role and trust rewrite](assets/7.3.png)

The check showed: **SAME PRINCIPAL, NEW CONDITION** ("has condition" went from False to True).

![Step 7 check](assets/7.4.png)

### Step 8: Limit `iam:PassRole` and add a ceiling

**Part 1:** I created the boundary **`USMSPermissionsBoundary`**. It allows only what USMS deploys need and **denies** every identity change (creating users, keys, attaching policies, etc.).

![Step 8 boundary](assets/8.png)

![Step 8 create boundary](assets/8.1.png)

**Part 2:** I created **`USMSDeployBase`**, which allows ECS deploys and `iam:PassRole` **only** on the three ECS roles and **only** to `ecs-tasks.amazonaws.com`, with an explicit **Deny** on passing any role to EC2.

![Step 8 deploy policy](assets/8.2.png)

**Part 3:** I created **`usms-deploy-role`** that only `usms-admin-01` can assume, with the boundary. The PassRole rules are correct, but Floci showed **`"Boundary": null`**: it accepted the boundary but did not store it. This is a known Floci limitation.

![Step 8 deploy role](assets/8.3.png)

### Step 9: Scope down a session

I wrote a session policy that only allows four "describe" actions.

![Step 9 session policy](assets/9.png)

I assumed `usms-developer-role` with it for 900 seconds. It worked, but Floci does not enforce session policies.

![Step 9 assume role](assets/9.1.png)

So I computed the result by hand: an action is allowed only if **both** the role and the session policy allow it. A session policy can **only take away permissions, never add them**.

![Step 9 intersection](assets/9.2.png)

### Step 10: Rotate the access key with no downtime

The safe order is: **create** the new key → **switch** to it → **deactivate** the old key → check → **delete** the old key. There is never a moment with no working key.

Before: `usms-dev-01` already had two keys from an earlier try (old Inactive, new Active).

![Step 10 keys before](assets/10.png)

Creating another key failed with **`LimitExceeded: Cannot exceed quota for AccessKeysPerUser: 2`**. AWS allows at most **two keys per user**, exactly enough for one old and one new key during rotation. The key file stayed empty, but Git ignores it.

![Step 10 create](assets/10.1.png)

I switched the profile and deactivated the old key.

![Step 10 switch and deactivate](assets/10.2.png)

I deleted the old key. **Exactly one active key is left.**

![Step 10 delete](assets/10.3.png)

Because the new key file was empty, the profile was set with empty values. It still worked only because Floci does not check credentials; on real AWS I would need to create a fresh key.

### Step 11: Require IMDSv2 on the web instance

`usms-web-01` had `HttpTokens: optional`, which still allowed IMDSv1. I changed it to **required** with a hop limit of **1**.

![Step 11 modify](assets/11.png)

**IMDSv2 REQUIRED, HOP LIMIT 1.** Now an attacker cannot read the role's credentials with a simple stolen request, and containers on the host cannot reach the metadata service.

![Step 11 after](assets/11.1.png)

### Step 12: Build the security group audit script

`usms-sg-audit.sh` reads every group in the VPC. The result was **HIGH=5, MED=11, LOW=6** for 8 groups. Most groups still had the **default allow-all egress**, and the EKS group accepted 443 from the whole VPC range.

![Step 12 SG audit](assets/12.png)

### Step 13: Egress rules for the enrolment tasks

I found the S3 prefix list **`pl-63a5400a`**.

![Step 13 prefix list](assets/13.png)

I wrote two egress rules: HTTPS to S3 through the prefix list, and HTTPS out for image pulls and logs.

![Step 13 egress document](assets/13.1.png)

I used the **safe order**: first add the new rules, then remove the default allow-all. If I removed first, there would be a moment with no outbound traffic at all.

![Step 13 authorise then revoke](assets/13.2.png)

The revoke returned True, but `describe-security-group-rules` still listed the old allow-all rule. This is a Floci inconsistency.

![Step 13 check](assets/13.3.png)

### Step 14: ALB egress to a security group

The ALB may now only send **port 80 to `usms-enrolment-sg`**, using a group reference instead of an IP range.

![Step 14 ALB egress](assets/14.png)

Inbound is still 80/443 from the internet, and outbound is only port 80 to the enrolment group. If task IPs change, the rule still works.

![Step 14 check](assets/14.1.png)

### Step 15: Data tier egress

The database may now only send **HTTPS (443) out**, for operating system updates.

![Step 15 DB egress](assets/15.png)

My check query failed with a `length()` error, because it was missing the `SecurityGroups[0].` prefix. The correct query is `length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'])`.

![Step 15 check](assets/15.1.png)

### Step 16: Move SSH to the bastion group

The group `usms-bastion-sg` already existed, but my lookup query returned nothing, because `| [0]` on a string gives null. So the bastion group ID variable was empty.

![Step 16 bastion group](assets/16.png)

The new SSH rule was created with an **empty source group**.

![Step 16 SSH rule](assets/16.1.png)

The old rule (SSH from `10.0.0.0/16`) was still listed after the revoke. **The SSH change is not finished.** The fix is to look the group up with `--query 'SecurityGroups[0].GroupId'`, recreate the rule with the real ID, and then remove the old rule.

![Step 16 check](assets/16.2.png)

### Step 17: Reachability matrix and negative proof

`usms-reachability-matrix.sh` builds a "who can reach whom" table from the rules. It shows my new egress rules on the ALB, enrolment and database groups, and points out four groups protected by **only one rule** (a single point of failure).

![Step 17 matrix](assets/17.png)

The negative proof checks that **`usms-db-01` cannot be reached from the internet** using five controls:

| Control | Holds? |
|---|---|
| 1. No public address | No on Floci (shows `127.0.0.1`) |
| 2. Subnet does not auto-assign public IPs | **Yes** |
| 3. Route table goes to a NAT gateway, not an internet gateway | **Yes** |
| 4. Security group has no IP range source | Partly |
| 5. Custom NACL attached | No (default NACL) |

Controls 2 and 3 each stop inbound internet traffic on their own, so the database is still protected.

![Step 17 negative proof](assets/17.1.png)

### Step 18: Restart test and regression check

I saved the security values before the restart: the trust conditions (**2**), the reader role and policy, **1** access key and IMDSv2 **required**.

![Step 18 before](assets/18.png)

I restarted Floci.

![Step 18 restart](assets/18.1.png)

Afterwards the values were the same: **PERSISTENCE PROVEN**. (Some egress lines were empty both times because of the Step 15 query bug.)

![Step 18 after](assets/18.2.png)

I ran the Lab 02–06 verify scripts again. The results were **exactly the same** as the baseline: **NOTHING BROKE**.

![Step 18 regression](assets/18.3.png)

### Step 19: Write configs/lab-09.env

The check printed "all values populated", but the file was actually **empty** (0 exports), because the heredoc did not run. The check passed only because there were no lines to fail. This file still needs to be written.

![Step 19](assets/19.png)

### Step 20: Commit

`git status` showed the new Lab 09 files and **nothing under `outputs/`**. The variable check flagged `${aws:username}` in one policy, but this is an **IAM policy variable** and must stay.

![Step 20 git status](assets/20.png)

Nothing was committed yet at the time of the screenshot.

![Step 20 git log](assets/20.1.png)

## 6. Verification

I ran `scripts/utilities/verify-lab-09.sh`. The result was **PASS=38, FAIL=12**.

The **passes** include: the deploy role trusts a user, `usms-dev-01` has exactly one active key, IMDSv2 is required, ALB egress goes to a group, the private route table has no internet gateway route, all policies are valid JSON and no secret is tracked by Git.

The **failures** come from two sources:

- **Floci limits:** the boundary is stored as `null`, revoked rules are still listed, the database rule has no source group, and instances show `127.0.0.1` as a public IP.
- **My own mistakes:** the empty bastion group ID (SSH rule), and a false positive on `${aws:username}`.

![Verification](assets/ver.png)

## 7. Analysis and Discussion

### 7.1 What was achieved

- All 9 roles, 5 users and 11 policies were inventoried, and two audit scripts found the weak points.
- A **read-only** transcripts policy and role were created with an explicit Deny on writes.
- The ECS task role now trusts **only this account's** ECS tasks.
- A deploy role can pass only three roles, only to ECS, with a permissions boundary.
- The developer key was **rotated** to one active key, and **IMDSv2** is required on the web server.
- The ALB, enrolment tasks and database now have **limited egress**.
- The setup survived a restart, and earlier labs gave **exactly the same results**.

### 7.2 Observations

- **Adding is safer than replacing.** I added a trust condition instead of removing permissions, so Lab 10 still works.
- **Order matters.** Add the new rule before removing the old one, and create a new key before deleting the old one.
- **Two keys per user is a feature.** It is exactly enough for a safe rotation.
- **A ceiling grants nothing.** Boundaries and session policies can only remove permissions.
- **Group references beat IP ranges.** They keep working when IPs change.
- **"True" does not always mean done on an emulator.** I learned to read state back with more than one API.
- **Checks can pass for the wrong reason.** "All values populated" passed on an empty file.

## 8. Reflection

### What I learned about securing a cloud application

Before this lab I thought security meant "add a policy". Now I see it as two separate questions: can this identity **call** the API, and can this server **reach** the other server? An IAM fix does nothing for an open security group, and the other way round. I also learned that a role has two policies: the trust policy decides who can become the role, and the identity policy decides what it can do. The confused deputy problem is in the trust policy, which I had never looked at closely before. The most useful idea was **least privilege by splitting**: instead of giving the reporting job the read-write policy because "it works", I made a read-only one.

### Challenges I faced

This lab had the most problems of any lab so far. My bastion group lookup returned nothing because of a small JMESPath mistake (`| [0]` on a string), so the SSH rule was created with no source. My `length()` queries were missing `SecurityGroups[0].`, so they failed. The second access key could not be created because of the two-key limit. These taught me to check every variable and query result before using it, and not to trust a "passed" message without looking at what was actually checked.

## 9. Conclusion

In this lab I reviewed and tightened the security of the whole USMS application. On the IAM side I built an inventory and audit script, created a read-only transcripts role, fixed the confused deputy problem, limited `iam:PassRole` with a deploy role and boundary, rotated an access key and required IMDSv2. On the network side I audited the security groups, added limited egress rules, and proved that the database is protected by its subnet and route table. The setup survived a restart, earlier labs were not broken, and the verification gave **PASS=38 FAIL=12**, where the failures come from Floci limits and a few mistakes that I recorded and still need to fix (the bastion SSH rule and `configs/lab-09.env`).

The key concepts I learned are the IAM evaluation order, trust vs identity policies, the confused deputy problem, permissions boundaries, safe key rotation, IMDSv2 and egress control. Security is important because one wrong permission or open port can expose all student data, and this lab gives USMS a safer base for Lab 10.
