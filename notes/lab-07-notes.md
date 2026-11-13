## Lab 07 support path
Probed on 2026-10-18T15:24:48Z
PATH A  - use aws eks throughout


## Step 20 - ECS and Kubernetes, compared with both running

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | | |
| What keeps N copies alive? | | |
| What gives it a stable name? | | |
| How does another service find it? | | |
| What does a rolling update create? | | |
| Where does rollback state live? | | |
| Which IAM role does the app code use? | | |
| What would I have to change to move to another cloud? | | |

Two sentences: which one would I choose for USMS, and why.

## Exercise 5 - what Lab 08 needs from configs/lab-07.env

| Variable | Why Lab 08 needs it |
| --- | --- |
| USMS_EKS_CLUSTER | every eks/kubectl command and the kubeconfig target this cluster |
| USMS_EKS_NODEGROUP | node scaling (min/max/desired) is changed on this node group |
| USMS_EKS_NAMESPACE | the HPA, PDBs and new objects go into the `usms` namespace |
| USMS_K8S_DEPLOY_ENROLMENT | the HPA's scaleTargetRef is this Deployment |
| USMS_K8S_CPU_REQUEST | HPA CPU % is measured against this 50m request; without a request HPA cannot work |
| USMS_K8S_DEPLOY_GATEWAY | the gateway gets its own PDB and is the entry point for load tests |
| USMS_K8S_SVC_GATEWAY | the gateway Service is what gets exposed outside the cluster (LoadBalancer / Ingress) |
| USMS_EKS_LB_PORTS | 8081/8082 are the load-balancer ports used to reach the exposed service |
| USMS_K8S_MANIFEST_DIR | Lab 08 manifests sit next to the Lab 07 ones |
| USMS_EKS_NODE_ROLE_ARN | extra nodes launched by scaling use this role |

Not needed by Lab 08: the cluster role/policy ARNs, cluster SG, endpoint, status, version and the
results/enrolment Service names. They describe how the cluster was built, not what gets scaled or exposed.
