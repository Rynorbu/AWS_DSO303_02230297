
## Step 12/13 - CodeBuild on Floci
- Build ID: usms-enrolment-build:1
- Result: buildStatus=FAULT, failed after DOWNLOAD_SOURCE
- Reason: "pull access denied for aws/codebuild/standard" - Floci cannot pull the
CodeBuild image
- Source zip verified correct (buildspec.yml at root, 6 files)
- Fallback: Step 14 local runner (Path B)

## Exercise 3 - why aws:SourceArn as well as aws:SourceAccount
- aws:SourceAccount only says "the CodeBuild project calling must be in account 000000000000".
  ANY project in this account - including one a developer creates tomorrow - could then use
  usms-codebuild-role and get its S3 and logs permissions (a confused-deputy / privilege-borrowing attack).
- aws:SourceArn names the exact project ARNs (usms-enrolment-build, usms-results-build), so only
  those two projects can make CodeBuild assume the role. A new or rogue project in
the same
  account is refused, even though it passes the account check.
