
## Step 4 - Your turn: HTTPS on usms-alb-sg
The load balancer still can't serve HTTPS for two reasons. There is no HTTPS listener on port 443, because the security group only opens the port and nothing is listening on it. And that listener would need an SSL/TLS certificate attached to it. AWS gives you the certificate for free through AWS Certificate Manager (ACM). The domain name the certificate is issued for is the thing you have to get from somewhere else: you buy it from a domain registrar, then prove you own it by adding a DNS record.

## Step 10 - Floci 2.0.1 limitation (Known Issues - Lab 05)
`aws ecs update-service --load-balancers ... --health-check-grace-period-seconds 60` returned success, but the readback showed `loadBalancers: null` and `healthCheckGracePeriodSeconds: null` (saved in outputs/lab-05-step10-readback.txt). The template was correct (enrolment-api, port 80, real target group ARN, no unexpanded `$`), so this is the documented Floci 2.0.1 gap, not a configuration error.
On real AWS the service would hold one loadBalancers entry and a 60s grace period, start a new deployment, and register each task's private IP into usms-enrolment-tg itself.
Alternative evidence: student-fallback-demo.py routing (path-based routing to two backends). It does NOT prove ALB health checks, target registration, TLS, security groups or ECS integration.
Note: the service runs usms-enrolment:1 (not :2 as the lab text assumes); no new revision was registered.
