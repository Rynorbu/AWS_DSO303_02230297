# Lab 07 Practical Report: Deploying the USMS Microservices on Amazon EKS

## 1. Aim / Objective

The aim of this lab is to run the University Student Management System (USMS) on **Kubernetes** using **Amazon EKS**. I created an EKS cluster and a managed node group inside the Lab 02 VPC, then deployed three microservices (`usms-gateway`, `usms-enrolment` and `usms-results`) with `kubectl`. The AWS side was done with the AWS CLI on the local emulator Floci.

The specific objectives were to:

- Understand the two halves of an EKS cluster (**control plane** and **data plane**) and why each needs its own IAM role.
- Create a **cluster role** (trusts `eks.amazonaws.com`) and a **node role** (trusts `ec2.amazonaws.com`), and attach Lab 01's `USMSStudentDataReadWrite` to the node role.
- Create the cluster `usms-eks-cluster` and the node group `usms-eks-nodes` in the private subnets.
- Deploy three services from **YAML manifests** and prove they find each other **by DNS name**.
- Use a **ConfigMap** and a **Secret**, do a **rolling update** and a **rollback**, and break pods on purpose to learn how to diagnose them.
- Prove everything survives a Floci restart, save the values to `configs/lab-07.env`, and check the lab with a verification script.

## 2. Introduction

**Amazon EKS (Elastic Kubernetes Service)** is AWS's managed Kubernetes. **Kubernetes** is an open-source system that runs containers on a group of machines, keeps the right number of copies running and replaces them when they fail. Unlike ECS, Kubernetes is not AWS-only: the same files work on any Kubernetes cluster.

An EKS cluster has two halves:

| Half | Who runs it | What is in it |
|---|---|---|
| **Control plane** | AWS | The API server, etcd (the cluster's database), the scheduler and the controllers |
| **Data plane** | Me | The **nodes** (EC2 instances) and my **pods** |

Because of this split there are **two IAM roles**: the control plane uses the **cluster role**, and the nodes use the **node role**.

The main Kubernetes objects I used:

| Object | Simple meaning | Comparison with ECS (Lab 04) |
|---|---|---|
| **Namespace** | A folder for objects. All mine are in `usms`. | Like the cluster name |
| **Pod** | One running copy of a container | Like one task |
| **Deployment** | "Keep N copies of this pod running." It creates a **ReplicaSet**, which creates the pods. | Like the ECS service |
| **Service (ClusterIP)** | A fixed name and IP in front of a group of pods | Like a load balancer / Cloud Map |
| **ConfigMap** | Normal settings given to pods | Environment in the task definition |
| **Secret** | Like a ConfigMap for passwords, but only **base64 encoded**, not encrypted | Like Secrets Manager |

Pods also have two health checks (probes):

- **Readiness probe:** "Can this pod take traffic?" If it fails, the pod is removed from the Service but not restarted.
- **Liveness probe:** "Is this pod stuck?" If it fails, the container is restarted.

This lab was done on **Floci**. Floci stores the EKS cluster and node group correctly, but it does not start real EC2 nodes. For the Kubernetes part I used a local **k3d** cluster with the same name, so all `kubectl` commands ran against a real Kubernetes API.

## 3. Use Case

**USMS use case:** USMS is made of many small services. A student's request first reaches a **gateway**, which sends it to the right service:

- `/enrolment/` goes to **usms-enrolment** (2 pods), for example when a student registers for a module.
- `/results/` goes to **usms-results** (2 pods), for example when a student checks their marks.

With Kubernetes, the gateway uses **DNS names** instead of IP addresses, so pods can be replaced without changing the gateway. Each service has 2 pods, so one can fail and the service still works. A new version can be rolled out without downtime, and rolled back with one command.

**Other real-world uses of EKS / Kubernetes:**

- Running large microservice systems (online shops, banking apps) with many teams.
- Running the same application on AWS, another cloud and on-premises with the same files.
- Running batch jobs, machine learning training and data processing on shared clusters.

## 4. System Architecture / Design

![USMS EKS architecture](assets/arch.png)

**How it works in simple words:**

1. The **AWS CLI** talks to Floci on port **4566** and creates the AWS objects: roles, security group, cluster and node group.
2. **kubectl** talks to the **Kubernetes API server** on port **6443**. These are two different tools and two different endpoints.
3. A request to the gateway is forwarded by nginx **by name** to the enrolment or results Service.
4. **CoreDNS** turns the name into the Service's ClusterIP, and **kube-proxy** spreads the traffic across the healthy pods.
5. The nodes live in the two **private subnets**, and the cluster security group only allows port 443 from inside the VPC.

## 5. Implementation Procedure

### Step 1: Start the environment

I loaded the env files (`course.env` and Labs 01–04) and ran `whoami.sh` and `floci-storage-check.sh`. The account is **000000000000** (Floci, not real AWS) and the storage mode is **hybrid**, so data survives a restart.

![Step 1](assets/1.png)

I ran the earlier verify scripts (Lab 02: **PASS=31, FAIL=2**, Lab 04: **PASS=39, FAIL=0**) and printed the four subnets. The two Lab 02 failures do not affect this lab, because the VPC and all four subnets are present.

![Step 1 verify](assets/1.1.png)

### Step 2: Find out what Floci supports

I wrote `scripts/utilities/eks-support-probe.sh`. The result was **PATH A - use aws eks throughout**: `eks list-clusters` worked, and kubectl, docker and python3 were installed.

![Step 2](assets/2.png)

I saved the result in `notes/lab-07-notes.md`.

![Step 2 verify](assets/2.1.png)

### Step 3: Control plane and data plane

This step was reading only (explained in Section 2). The key point: an ACTIVE cluster with **no nodes runs nothing**.

### Step 4: Write the two trust policies

A trust policy says **who may use a role**:

- `trust-eks-cluster.json` trusts **`eks.amazonaws.com`** (the control plane).
- `trust-eks-node.json` trusts **`ec2.amazonaws.com`** (nodes are EC2 instances).

![Step 4](assets/4.png)

Both files are valid JSON and show `sts:AssumeRole` for the right service.

![Step 4 verify](assets/4.1.png)

### Step 5: Write the two permissions policies

On real AWS I would attach the AWS managed EKS policies. Floci may not have them, so I wrote my own versions:

| Policy | What it allows |
|---|---|
| **USMSEKSClusterPolicy** | Manage network interfaces and load balancers, and **Deny** outside `us-east-1` |
| **USMSEKSNodePolicy** | Join the cluster, give pods IP addresses, pull images from ECR, write logs to `/usms/eks/*`, and **Deny** outside `us-east-1` |

![Step 5](assets/5.png)

![Step 5 verify](assets/5.1.png)

### Step 6: Create the cluster role and security group

**Part 1:** `create-role` said `EntityAlreadyExists` because of an earlier try, so I read the role back and updated its trust policy to match my file.

![Step 6 part 1](assets/6.png)

**Part 2:** I created `USMSEKSClusterPolicy` and attached it.

![Step 6 part 2](assets/6.1.png)

**Part 3:** I created `usms-eks-cluster-sg` in the Lab 02 VPC, allowing **TCP 443 only from `10.0.0.0/16`**. The Kubernetes API is an admin API, so it should not be open to the internet.

![Step 6 part 3](assets/6.2.png)

**Verify:** the role has the policy and trusts `eks.amazonaws.com`, and the security group is in `vpc-20628f13` on port 443.

![Step 6 verify](assets/6.3.png)

### Step 7: Create the node role and attach Lab 01's policy

I created `usms-eks-node-role` and attached `USMSEKSNodePolicy`.

![Step 7 part 1](assets/7.png)

Then I attached Lab 01's `USMSStudentDataReadWrite` without changing it. This policy now has **three holders**: the EC2 role (Lab 03), the ECS task role (Lab 04) and the EKS node role.

![Step 7 part 2](assets/7.1.png)

![Step 7 verify](assets/7.2.png)

### Step 8: Create the cluster

**Part 1:** I wrote `templates/lab-07-create-cluster.json` with all **four subnets** and the tag **`_lb_ports_: 8081,8082`**, which Lab 08 needs to expose services.

![Step 8 part 1](assets/8.png)

**Part 2:** I assumed `usms-developer-role` from Lab 01 to create the cluster.

![Step 8 part 2](assets/8.1.png)

**Part 3:** `aws eks create-cluster` returned **CREATING**, version **1.30**.

![Step 8 part 3](assets/8.2.png)

I also created a local **k3d** cluster with the same name (1 server, 2 agents), which I used for all `kubectl` work.

![Step 8 k3d](assets/8.3.png)

**Part 4:** I unset the assumed-role credentials and returned to my normal identity.

![Step 8 part 4](assets/8.4.png)

### Step 9: Wait for the cluster

`aws eks wait cluster-active` finished and the status became **ACTIVE**.

![Step 9](assets/9.png)

Reading it back showed version **1.30**, **4 subnets** in the Lab 02 VPC, the security group, and the `_lb_ports_` tag.

![Step 9 verify](assets/9.1.png)

![Step 9 tag](assets/9.2.png)

### Step 10: Create the managed node group

I created `usms-eks-nodes` with **min 2, max 4, desired 2**, instance type `t3.small`, and only the **two private subnets**. Nodes should never be in a public subnet.

![Step 10 part 1](assets/10.png)

![Step 10 part 2](assets/10.1.png)

**Verify:** status **ACTIVE**, private subnets only, role `usms-eks-node-role`.

![Step 10 verify](assets/10.2.png)

### Step 11: Point kubectl at the cluster

`aws eks update-kubeconfig` added the context `usms-eks`. I then switched to the k3d context **`k3d-usms-eks-cluster`** for the Kubernetes steps.

![Step 11 part 1](assets/11.png)

![Step 11 k3d](assets/11.1.png)

`kubectl get nodes` shows **3 nodes, all Ready**, on Kubernetes v1.30.

![Step 11 part 2](assets/11.2.png)

I saved the kubeconfig to `outputs/lab-07-kubeconfig.yaml` with `chmod 600`, because it contains certificates. Git ignores it.

![Step 11 fallback](assets/11.3.png)

![Step 11 ignore](assets/11.4.png)

**Verify:** 3 nodes, and `auth can-i create deployments` says **yes**.

![Step 11 verify](assets/11.5.png)

### Step 12: Create the namespace

I applied `00-namespace.yaml` to create **`usms`** and made it my default namespace.

![Step 12 part 1](assets/12.png)

![Step 12 part 2](assets/12.1.png)

![Step 12 verify](assets/12.2.png)

### Step 13: Deploy usms-enrolment

I created the shared ConfigMap `usms-app-config` with 4 keys (environment, campus, version `1.0.0`, region).

![Step 13 part 1](assets/13.png)

`20-enrolment.yaml` contains a Deployment with **2 replicas**, a CPU request of **50m** (needed for Lab 08), readiness and liveness probes on `/healthz`, a safe rolling update (`maxUnavailable: 0`), and a ClusterIP Service.

![Step 13 part 2](assets/13.1.png)

**Verify:** the Deployment is **2/2**, the pods are on **different nodes**, and the Service has **2 endpoints**.

![Step 13 verify](assets/13.2.png)

A test pod called `http://usms-enrolment.usms.svc.cluster.local/` and got JSON with the pod name and version 1.0.0.

![Step 13 part 3](assets/13.3.png)

### Step 14: Deploy usms-results

`30-results.yaml` is similar but has no liveness probe and uses the default rolling update.

![Step 14](assets/14.png)

Both Deployments are **2/2** and each Service has 2 endpoints.

![Step 14 verify](assets/14.1.png)

### Step 15: Deploy the gateway

The gateway is an nginx reverse proxy with **no IP addresses**, only two DNS names for `/enrolment/` and `/results/`. I deployed it last, because nginx looks up the names when it starts.

![Step 15](assets/15.png)

**Verify:** **5 pods Running** (2 enrolment, 2 results, 1 gateway).

![Step 15 verify](assets/15.1.png)

### Step 16: Prove service discovery

`nslookup` from inside a pod showed that each service name resolves to its **ClusterIP**, served by CoreDNS.

![Step 16 part 1](assets/16.png)

Through the gateway, `/`, `/enrolment/` and `/results/` all answered.

![Step 16 part 2](assets/16.1.png)

I sent **12 requests** to `/enrolment/` and they were split **6 and 6** across the two pods. The gateway only knows one name, and Kubernetes spreads the load.

![Step 16 part 3](assets/16.2.png)

### Step 17: ConfigMaps and Secrets

I created `usms-enrolment-secret` with two **dummy** values.

![Step 17 part 1](assets/17.png)

With just `base64 -d` the stored value turned back into **`floci-dummy-token-not-a-real-secret`**. No key was needed: **a Secret is encoded, not encrypted.**

![Step 17 part 2](assets/17.1.png)

I added the Secret to the enrolment Deployment, which started a new rollout.

![Step 17 part 3](assets/17.2.png)

Inside the container, `printenv` shows the 4 `APP_*` values and the 2 Secret values in plain text.

![Step 17 verify](assets/17.3.png)

### Step 18: Roll out a change, then roll it back

I changed `APP_VERSION` from **1.0.0 to 1.1.0** in the ConfigMap.

![Step 18 part 1](assets/18.png)

The pod still answered **1.0.0**, because pods read their environment only when they start.

![Step 18 part 2](assets/18.1.png)

Annotating the Deployment's own metadata did not roll anything, because the pod template did not change.

![Step 18 part 3](assets/18.2.png)

`rollout history` showed **2 revisions** (the first apply, and the Secret change).

![Step 18 history](assets/18.3.png)

`rollout undo` went back to revision 1, but the new pod answered **1.1.0**. A rollback only reverts the **pod template**, not the ConfigMap.

![Step 18 undo](assets/18.4.png)

I set the ConfigMap back to 1.0.0 and restarted the Deployment.

![Step 18 restore](assets/18.5.png)

### Step 19: Break pods on purpose and diagnose them

**Bad image:** the new pod went into **ImagePullBackOff**, but the **two old pods kept running**, so users were not affected.

![Step 19 failure 1](assets/19.png)

I fixed it with `rollout undo`.

![Step 19 fix](assets/19.1.png)

**Too much CPU:** I asked for 64 CPUs. The pod stayed **Pending**, and `describe` showed **FailedScheduling: Insufficient cpu, Insufficient memory**. The answer was in the Events, not in the logs, because the container never started.

![Step 19 failure 2](assets/19.2.png)

For a **CrashLoopBackOff** (no screenshot), the right command is `kubectl logs --previous`, because the container does start and prints its error.

### Step 20: ECS and Kubernetes side by side

I looked at both platforms at the same time. ECS showed `usms-enrolment-svc` and EKS showed 3 Deployments and 3 ClusterIP Services.

![Step 20](assets/20.png)

![Step 20 notes](assets/20.1.png)

| Question | ECS | Kubernetes |
|---|---|---|
| What holds the container spec? | Task definition | Pod template in the Deployment |
| What keeps N copies alive? | ECS service | ReplicaSet |
| How does another service find it? | ALB DNS name | Cluster DNS name |
| Where does rollback state live? | Old task definition revisions | Old ReplicaSets |
| Moving to another cloud? | Almost everything changes | Manifests stay the same |

**My choice for USMS:** ECS on Fargate, because USMS is small, runs in one region and ECS needs far fewer steps. Kubernetes is better if USMS must be portable or grows into many services.

### Step 21: IRSA

**IRSA** (IAM Roles for Service Accounts) gives an IAM role only to the pods that use one ServiceAccount, instead of to every pod on the node. My Floci build published an **OIDC issuer**, so I created the OIDC provider.

![Step 21 parts 1 and 2](assets/21.png)

I created the ServiceAccount `usms-enrolment-sa`. I did not create the workload role or annotate the ServiceAccount, so IRSA is only partly set up.

![Step 21 part 3](assets/21.1.png)

### Step 22: Restart test

I recorded the state before the restart.

![Step 22 part 1](assets/22.png)

I stopped Floci and started it again in hybrid mode.

![Step 22 part 2](assets/22.1.png)

After the restart, the cluster, node group, namespace, Deployments and ConfigMaps were all still there. The cluster briefly showed CREATING but was ACTIVE a minute later.

![Step 22 part 3](assets/22.2.png)

### Step 23: Save the values

I wrote `configs/lab-07.env` with values looked up from the API. All values were populated.

![Step 23](assets/23.png)

The file has **21 exports**.

![Step 23 verify](assets/23.1.png)

### Step 24: Commit

`git status` showed no file under `outputs/`, and `git check-ignore` proved they are ignored by `outputs/*`.

![Step 24 part 1](assets/24.png)

No output file is tracked by Git.

![Step 24 part 2](assets/24.1.png)

## 6. Verification

I ran `scripts/utilities/verify-lab-07.sh`, which checks the environment, earlier labs, IAM roles, the cluster, the Kubernetes objects and Git hygiene. The result was **PASS=30, FAIL=0**.

![Verification](assets/veri.png)

The smoke test called `/`, `/enrolment/` and `/results/` through the gateway and printed **SMOKE TEST PASSED**.

![Smoke test](assets/veri.1.png)

## 7. Analysis and Discussion

### 7.1 What was achieved

- The cluster `usms-eks-cluster` was created across four subnets with the `_lb_ports_` tag for Lab 08.
- The node group `usms-eks-nodes` was created in the **private subnets only**.
- Two IAM roles were created, and Lab 01's policy was attached to the node role as its third holder.
- Three microservices were deployed in the `usms` namespace, each with healthy pods.
- Services found each other by DNS, and traffic was spread evenly across pods.
- Rollout, rollback, failures and a restart were all tested.

### 7.2 Observations

- **Two tools, two endpoints.** The AWS CLI created the cluster in Floci, but kubectl talked to the Kubernetes API on port 6443.
- **Names, not IP addresses.** The gateway only knows DNS names, so pods can be replaced freely.
- **ConfigMap changes need a restart.** Pods only read settings when they start.
- **Rollback is not complete.** `rollout undo` reverted the pod template but not the ConfigMap.
- **Rolling updates protect users.** With a bad image, the old pods kept serving.
- **`describe` before `logs`.** If the container never started, the answer is in the Events.
- **A Secret is not a lock.** One `base64 -d` command showed the token.
- **Floci limits.** Floci records IAM policies and the node group size, but does not enforce them or start real EC2 nodes.

## 8. Reflection

### What I learned about Kubernetes

Before this lab, I thought EKS was just ECS with different names. Now I understand that AWS runs the control plane, but I am responsible for the nodes, and each half needs its own role. I also learned that most of the work is in Kubernetes objects that know nothing about AWS, so the same YAML files would work on any cluster. The moment that made it clear was service discovery: the gateway only knows a name, and when I sent 12 requests they were split 6 and 6 across two pods without me configuring anything.

### Challenges I faced

My biggest problem was working in **two copies of the project**, one in Windows and one in WSL. Files created in one folder were missing in the other, so I got "No such file or directory" errors. I learned to check my prompt and use one folder for the whole lab. I also had problems copying commands from the web page, and `create-role` failed with `EntityAlreadyExists`. Instead of deleting the role, I read it back and checked it was correct.

## 9. Conclusion

In this lab I deployed the USMS application as three microservices on Amazon EKS. All objectives were achieved: I created the cluster and node roles, a security group, the cluster with the `_lb_ports_` tag, the node group in the private subnets, and deployed the gateway, enrolment and results services from YAML. Everything survived a restart, and the verification script passed **30 of 30** checks.

The key concepts I learned are the control plane / data plane split, Deployments, ReplicaSets and Services, DNS-based service discovery, the fact that a Secret is only base64, and that a rollback does not revert a ConfigMap. Kubernetes is important because it runs containers the same way on any cloud, and this lab prepares the cluster for scaling and exposing the services in Lab 08.
