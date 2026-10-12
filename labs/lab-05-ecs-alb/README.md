# Lab 05 Practical Report: Putting the ECS Service Behind an Application Load Balancer

## 1. Aim / Objective

The aim of this lab is to put the USMS **enrolment service** from Lab 04 behind an **Application Load Balancer (ALB)**, so that it has one stable address and the tasks themselves stay private. Everything was done with the AWS CLI on the local emulator Floci.

The specific objectives were to:

- Create an **internet-facing ALB** (`usms-enrolment-alb`) in the two public subnets from Lab 02, with its own security group (`usms-alb-sg`).
- Create a **target group** (`usms-enrolment-tg`) with `--target-type ip`, a health check on `/`, and a 30-second deregistration delay.
- Create a **listener** on HTTP port 80 that forwards to the target group, and one **listener rule** that answers `/alb-health` directly.
- Attach the existing ECS service to the target group so that **ECS registers its own tasks**, not me.
- Do a **security cutover**: make the load balancer the only thing that can reach the tasks, and remove the old direct path from the web server.
- Prove that everything survives a Floci restart, save all the ARNs to `configs/lab-05.env` for Lab 06, and check the lab with a verification script.

## 2. Introduction

**Elastic Load Balancing (ELB)** is the AWS service that spreads incoming traffic across many targets, such as EC2 instances, containers or IP addresses. An **Application Load Balancer (ALB)** is the type of load balancer that works at layer 7 (HTTP/HTTPS). That means it can read the request and make decisions based on the URL path or headers, for example "send `/results` to one service and everything else to another".

In Lab 04 the enrolment tasks were running, but they had **private, temporary IP addresses** that changed every time a task was replaced. Nobody could call them by a fixed name. The ALB solves this: it gives one stable DNS name, checks which tasks are healthy, and sends requests only to healthy ones.

An ALB is built from four objects:

| Object | Simple meaning |
|---|---|
| **Load balancer** | The front door. It has a DNS name, lives in subnets, and has a security group. |
| **Listener** | Waits on one port and protocol (here HTTP:80). It has exactly one **default action**. |
| **Rule** | "If the request matches this condition, do this action." Lowest priority number is checked first. |
| **Target group** | The list of targets (task IPs) plus the **health check**. The health check lives here, not on the load balancer. |

## 3. Use Case

**USMS use case:** The enrolment API from Lab 04 runs as two Fargate tasks in two private subnets. During enrolment week, students and the USMS web portal need to reach it reliably. With the ALB:

- Clients call **one stable DNS name** instead of task IPs that keep changing.
- The ALB only sends traffic to **healthy** tasks. If a task in one Availability Zone dies, traffic goes to the other one.
- During a deployment, old tasks are **drained** (finish their current requests) before being stopped, so students do not see errors.
- The tasks stay in **private subnets with no public IP**. The only way in from the internet is through the listener and the security group I wrote.
- In Lab 06, auto scaling can use **requests per target** from this target group as its scaling signal.

## 4. System Architecture / Design

![alt text](assets/arch.png)

**How it works in simple words:**

1. A user (or the USMS portal) sends a request to the ALB's DNS name. It comes in through the **Internet Gateway** (`usms-igw`).
2. The ALB has a node in **each public subnet** (us-east-1a and us-east-1b). Its security group `usms-alb-sg` allows port 80 from anywhere.
3. The **listener** on HTTP:80 checks the rules. If the path is `/alb-health`, the rule at priority 10 answers `200` straight away without touching any task. Otherwise the **default action** forwards the request to `usms-enrolment-tg`.
4. The target group holds the **private IPs of the tasks** and checks their health with `GET /` every 30 seconds.
5. The tasks are protected by `usms-enrolment-sg`, which now only accepts port 80 **from `usms-alb-sg`**. The old rule that let `usms-web-01` call the tasks directly was removed.
6. The **ECS service** is responsible for putting task IPs into the target group and taking them out. I never register targets by hand.

## 5. Implementation Procedure

### Step 1: Start the environment

I started Floci and loaded the env files from Labs 01–04. `whoami.sh` showed account `000000000000`, so I was working on Floci, not real AWS. All the values I needed were there, including **both public subnets**. An ALB needs two subnets in two different Availability Zones.

![Step 1](assets/1.png)

### Step 2: Check the earlier labs

I ran the earlier verification scripts. Lab 04 passed **38/38**, and I saved that result as a "before" copy to compare with in Step 13. Lab 02 showed 2 failures and Lab 03 showed 1, but these were in parts this lab does not use.

![Step 2](assets/2.png)

### Step 3: Test what Floci supports

I tested the load balancer commands before building anything, and all of them answered **SUPPORTED**. Later I found that Floci can create and store load balancer objects, but it cannot send real traffic through them. So my build is **path B (control plane only)**.

![Step 3](assets/3.png)

### Step 4: Create the load balancer's security group

I created `usms-alb-sg` and allowed **HTTP port 80 from anywhere (`0.0.0.0/0`)**. This is fine because an internet-facing load balancer must accept the internet, and the tasks behind it stay private.

![Step 4 part 1](assets/4.png)

![Step 4 part 2](assets/4.1.png)

![Step 4 verify](assets/4.2.png)

**Your turn:** I added a rule for **port 443 (HTTPS)**. But opening a port is not enough for HTTPS. You also need an **HTTPS listener** and a **certificate**. The certificate is free from AWS Certificate Manager, but you have to buy the **domain name** yourself.

![Your turn 1](assets/your_turn_1.png)

![Your turn 2](assets/your_turn_2.png)

### Step 5: Create the load balancer

I created `usms-enrolment-alb` as an **internet-facing Application Load Balancer** in both public subnets. Its state became `active` straight away; on real AWS this takes 2–4 minutes. I also set two settings: a 60-second idle timeout, and dropping bad headers for security.

![Step 5 part 1](assets/5.png)

![Step 5 part 2](assets/5.1.png)

![Step 5 verify](assets/5.2.png)

![Step 5 part 3](assets/5.3.png)

### Step 6: Create the target group

I created `usms-enrolment-tg`, the list of tasks the ALB sends traffic to:

- **Target type `ip`:** Fargate tasks have no server ID, only an IP address.
- **Health check:** `GET /` every 30 seconds. A task is "healthy" if it returns **200**.

The target group was **empty**, which is correct. The ECS service adds the tasks, not me.

![Step 6](assets/6.png)

![Step 6 verify](assets/6.1.png)

**Your turn:** I changed the health check to also accept redirects (`200-399`), checked it, and changed it back to `200`. It updated straight away without recreating anything.

![Your turn 3](assets/your_turn_3.png)

![Your turn 4](assets/your_turn_4.png)

![Your turn 5](assets/your_turn_5.png)

### Step 7: Set how tasks are removed

I set the **deregistration delay to 30 seconds**. When a task is stopped, it gets 30 seconds to finish the requests it is already serving. I also chose **least outstanding requests**, so new requests go to the least busy task.

![Step 7](assets/7.png)

### Step 8: Create the listener

The listener waits for requests on **HTTP port 80** and **forwards** them to the target group. Now the target group is connected to the load balancer.

![Step 8 part 1](assets/8.png)

![Step 8 part 2](assets/8.1.png)

![Step 8 verify](assets/8.2.png)

### Step 9: Let the load balancer reach the tasks

I added a rule to the tasks' security group (`usms-enrolment-sg`) so it accepts port 80 **from `usms-alb-sg`**. For a short time both the web server and the ALB could reach the tasks. That was on purpose: build the new path first, then remove the old one.

![Step 9](assets/9.png)

![Step 9 verify](assets/9.1.png)

### Step 10: Connect the ECS service to the target group

I told the ECS service to put its tasks into the target group (container `enrolment-api`, port 80), with a 60-second grace period.

The command **worked**, but when I read it back, the settings were **empty (`null`)**. My file was correct. This is a **known Floci 2.0.1 problem**: it accepts these settings but does not save them.

![Step 10 part 1](assets/10.png)

![Step 10 part 2](assets/10.1.png)

### Step 11: Watch the targets

Because of the Step 10 problem, the target group **stayed empty**. The service itself was fine, with **2 tasks running**. Floci also does not show task IPs or health.

![Step 11 part 1](assets/11.png)

![Step 11 part 2](assets/11.1.png)

![Step 11 part 3](assets/11.2.png)

**Your turn:** I scaled the service to 3 tasks and back to 2. The task count changed (2 → 3 → 2), but the target group stayed empty on Floci. On real AWS, the service would add and remove the targets by itself. Without that, I would have to add and remove every task's IP by hand after each scaling.

### Step 12: Prove the path

I tried to open the ALB's address with `curl`. The name **did not resolve** and I got **no response (`000`)**, because Floci does not run a real load balancer.

![Step 12 part 1](assets/12.png)

Instead, I proved the setup by reading it from the API: listener → target group → security group. These links were all correct. Only the targets were missing, because of the Step 10 problem.

![Step 12 part 2](assets/12.1.png)

### Step 13: Remove the old direct path

I removed the old rule that let the web server (`usms-app-sg`) reach the tasks directly.

![Step 13 part 1](assets/13.png)

![Step 13 part 2](assets/13.1.png)

Floci replied `True`, but the rule was **still there**. I found this later and removed it again with a different form of the command. After that, **only the ALB** could reach the tasks.

![Step 13 verify](assets/13.2.png)

Lab 04's script then showed **1 failure**, which is **expected**, because I changed Lab 04's design on purpose.

![Step 13 part 3](assets/13.3.png)

### Step 14: Force a new deployment

I saved the state, then forced ECS to replace all tasks. Floci finished it **instantly**, so I could not see tasks being drained. I also found and fixed a small mistake in the lab's polling command (`length(deployments)` should be `length(services[0].deployments)`).

![Step 14 part 1](assets/14.png)

![Step 14 part 2](assets/14.1.png)

### Step 15: Add a listener rule

I added a rule at **priority 10**: requests to `/alb-health` get a fixed **200 "ok"** reply, without going to any task. All other requests use the default forward action. `curl` could not test it on Floci, but `describe-rules` shows the rule is there.

![Step 15 part 1](assets/15.png)

![Step 15 part 2](assets/15.1.png)

![Step 15 verify](assets/15.2.png)

![Step 15 part 3](assets/15.3.png)

### Step 16: Restart test

I saved the setup, restarted Floci, looked up everything again, and compared. Nothing changed: **PERSISTENCE PROVEN**.

![Step 16 part 1](assets/16.png)

![Step 16 part 2](assets/16.1.png)

![Step 16 part 3](assets/16.2.png)

### Step 17: Final security check

This check showed who can reach what. When I took this screenshot it said **MISMATCH**, because the Step 13 rule was still there. This is how I found that problem. After fixing it, only the ALB can reach the tasks.

![Step 17](assets/17.png)

### Step 18: Save the values

I saved the ALB, target group and listener values to `configs/lab-05.env` for Lab 06. Three service values are `None` because of the Step 10 Floci problem. The listener ARN came out empty and needs to be filled in again.

![Step 18](assets/18.png)

![Step 18 verify](assets/18.1.png)

### Step 19: Commit

I checked that nothing from `outputs/` (which has secret files) would be committed, and added the Lab 05 files by name.

![Step 19 part 1](assets/19.png)

![Step 19 part 2](assets/19.1.png)

### Verification

The verification script gave **PASS=43, FAIL=6**.

![Verification](assets/ver.png)

All 6 failures come from **one cause**: the Floci problem in Step 10, where the service does not save its load balancer settings. On real AWS they would all pass. All the important checks passed: target type `ip`, two Availability Zones, health check `200`, the listener rule, and **only the ALB can reach the tasks**.

## 7. Analysis and Discussion

### 7.1 What was achieved

I put the enrolment service behind an internet-facing ALB across two Availability Zones. I created a target group (`ip` type, health check on `/`), a listener on port 80 and a rule for `/alb-health`. After the cutover, **only the load balancer can reach the tasks**. Everything survived a restart, and the values were saved in `configs/lab-05.env` for Lab 06.

### 7.2 Observations

- **The ECS service adds and removes the targets, not me.** I never need `register-targets`.
- **Fargate needs `--target-type ip`**, because its tasks have no instance ID.
- **A success message is not proof.** Two commands said success but did nothing. Only reading back showed the truth.
- **Build the new path first, then remove the old one.** That way the change causes no downtime.

## 8. Reflection

### What I learned about load balancers

Before this lab, I thought a load balancer was just one thing that splits traffic between servers. When I built it myself, one piece at a time, I saw it is actually four pieces. The **load balancer** is the front door with one fixed name. The **listener** waits on a port, port 80 in my case. The **rules** decide where each request should go. The **target group** is the list of tasks that do the real work. Once I saw it like this, it was much easier to follow what happens to a request.

The part that surprised me was that the health check sits on the target group, not on the load balancer. At first I didn't understand why. Then I thought about it: one load balancer can send traffic to many different target groups, like `/enrolment` to one service and `/results` to another, and each service has to be checked in its own way. So it makes sense for each target group to check its own tasks.

### Challenges I faced

My biggest problem was that Floci sometimes said a command worked when it really didn't. In Step 10, I connected the ECS service to the target group and got no error. But when I checked the service, the load balancer setting was `null`. I thought I had typed something wrong, so I went through my JSON file line by line and checked the container name, the port and the ARN. Everything was correct. Then I found on the Known Issues page that this is a bug in Floci 2.0.1. 

## 9. Conclusion

In this lab I put the USMS enrolment service behind an Application Load Balancer using only the AWS CLI. I created the ALB security group, an internet-facing ALB across two Availability Zones, a target group with `ip` targets and a deliberate health check, a listener with a default action, and a listener rule. I also cut over the security groups so that only the load balancer can reach the tasks.

The main things I learned are the four ALB objects, why Fargate needs `--target-type ip`, that the ECS service manages the target group, how health checks, grace periods and draining work together during a deployment, and how to change a security design safely by building the new path before removing the old one. I also learned to be honest about what I actually saw versus what I only reasoned about. Load balancers are important because they give a stable entry point, which makes zero-downtime deployments and the auto scaling in Lab 06 possible.