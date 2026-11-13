metrics API unavailable - Step 9 will use the manual fallback

## Step 17 - Practical 2 and Practical 4, compared with both running

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | | |
| Who writes it? | | |
| Where does that thing run? | | |
| Where does the metric come from? | | |
| What does "50% CPU" mean - 50% of what? | | |
| How is scale-in slowed down? | | |
| What happens if there is no capacity for the new instance/pod? | | |
| What creates the alarms, if anything? | | |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | | |
| What is the target type, and why? | | |
| How are targets registered and deregistered? | | |
| How are competing routing rules disambiguated? | | |
| What would I change to move this to another cloud? | | |
| What is the cost of exposing ten services? | | |

### Two paragraphs, in prose

1. If the AWS control plane has a bad afternoon, what happens to each of the two
   scaling arrangements, and which of them can I still debug?

2. For USMS specifically - one small team, one region, quiet for eight months and
   very busy for two - which would I choose, and what is the strongest argument
   AGAINST my own choice?

## ECS or Kubernetes for USMS

**Recommendation: ECS (Fargate) for USMS.** USMS is one small team in one region, with a
traffic pattern that is quiet for eight months and very busy at enrolment and results
time. The scaling we need is "add tasks when CPU rises, remove them afterwards", and
ECS Service Auto Scaling with an ALB gives that with far fewer moving parts. There are
no nodes to patch, no metrics-server to keep alive and no PDBs to tune before a drain.

**Strongest argument against:** Kubernetes is portable and expressive. One set of
manifests (HPA, PDB, topology spread, Ingress) describes scaling, availability and
exposure together, it runs the same on k3d, EKS or any other cloud, and the skills
transfer. If USMS grows into many services or must leave AWS, ECS would be the thing
we have to rewrite.

**Observations from Practicals 2 (ECS) and 4 (EKS):**

1. In ECS the scaling was one layer (service desired count driven by a CloudWatch
   alarm). In EKS it was two separate layers: the HPA scales pods, and the node group
   (min 2 / max 4) must have room for them. Both have to be tuned, and they can
   disagree.
2. The EKS HPA silently did nothing when the pod had no CPU request (`<unknown>`) or
   when min = max (Exercise 3). ECS never needed a "request" for scaling to work, so
   that class of fault did not exist there.
3. Availability in EKS needed extra objects. My gateway PDB with 1 replica had 0
   allowed disruptions and blocked a node drain until I raised replicas to 2 and added
   a topology spread. ECS handled task replacement across AZs for me.
4. Exposure: one ALB with listener rules in ECS did the same job as one Ingress
   controller with two Ingress objects here. Both avoid paying for a second load
   balancer, but the Ingress annotations are inert locally, so I could only half-test
   the EKS version.

For USMS today the operational cost of Kubernetes is larger than its flexibility is
worth, so I would choose ECS and revisit if the service count grows.
