
## Step 12/13 - CodeBuild on Floci
- Build ID: usms-enrolment-build:1
- Result: buildStatus=FAULT, failed after DOWNLOAD_SOURCE
- Reason: "pull access denied for aws/codebuild/standard" - Floci cannot pull the
CodeBuild image
- Source zip verified correct (buildspec.yml at root, 6 files)
- Fallback: Step 14 local runner (Path B)
