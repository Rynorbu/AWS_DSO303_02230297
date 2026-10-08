# Lab 03 Notes: Amazon EC2

## 1. What if one of the five launch inputs was wrong or missing?

There are two kinds of mistakes. If an ID **does not exist**, AWS rejects the launch **immediately**. If the value is **real but wrong**, or **left out**, the instance launches fine and the problem only shows up later (**silent**).

- **Subnet (Lab 2):** a fake ID fails immediately. A wrong but real subnet (for example the private one) is silent: the server runs, but it has no public IP and no route to the internet, so nobody can reach it.
- **Security group (Lab 2):** a fake ID, or one from another VPC, fails immediately. A wrong group (for example `usms-db-sg`) is silent: port 80 is closed. If it is left out, AWS uses the VPC's default group, which is also silent and also blocks the website.
- **Instance profile (Lab 1):** a fake name fails immediately. If it is missing or wrong, it is silent: the server runs, but the app gets `Unable to locate credentials` or `AccessDenied` only when it tries to use S3, maybe days later.
- **Key pair (Lab 3):** a fake name fails immediately. If it is missing, it is silent: the server runs, but nobody can log in with SSH when something needs fixing.
- **User-data script (Lab 3):** a wrong file path or a script over 16 KB fails immediately. A script with a bug is silent: the instance still shows `running`, but nginx is never installed. The error is only in a log file on the server.

**In short:** AWS checks that things exist and fit together. It does not check that they are the right choice.

## 2. Why a policy for a bucket that does not exist is valid

An IAM policy is just a set of rules about **names**. When the policy is created, AWS does not check if the bucket `usms-student-data` exists. It only checks the policy when a request is made, by comparing the name in the request with the name in the policy. So today the instance already has permission: `usms-web-01` → `usms-ec2-app-profile` → `usms-ec2-app-role` → `USMSStudentDataReadWrite` → `usms-student-data`. Requests still fail, but only because the bucket is not there. In Exercise 5, `head-bucket` returned **404 Not Found** (bucket missing), not **403 Access Denied** (no permission). When Lab 4 runs `create-bucket`, **nothing on the EC2 or IAM side changes**: no policy edit, no restart, no new credentials. The name in the policy now points to a real bucket, so the next request just works. This is the most important link so far, because Lab 1 (permissions), Lab 3 (server) and Lab 4 (storage) are connected only by this shared name. One risk: bucket names are unique across all of AWS, so if someone else takes the name first, we cannot create it.

## 3. Why "restart to redeploy" with user data does not work

User data runs **only once**, on the first boot of an instance. On a restart it is skipped, so the app is **not** redeployed and the old version keeps running. Even if it were forced to run on every boot, it would be slow, a failed deploy would leave a broken server, and it is limited to 16 KB.

Two approaches that work:

1. **Golden AMI:** for each new version, build a new AMI with the app already installed (like Step 20). An Auto Scaling group then replaces the old servers with new ones. To roll back, go back to the old AMI.
2. **Deployment tool:** user data only does the first setup. New versions are pushed to the running servers with **AWS CodeDeploy** or **AWS Systems Manager Run Command**, with no reboot needed.

## 4. Auto-assigned public IP vs Elastic IP

| | Auto-assigned public IP | Elastic IP |
|---|---|---|
| **Who owns it** | AWS. The instance only borrows it | My account, until I release it |
| **When it changes** | Every stop and start | Never |
| **Cost** | $0.005/hour while in use | $0.005/hour, **even when not attached** to anything |
| **When the instance stops** | Released. A new one comes on start | Stays attached and comes back with the instance |

**Failover this makes possible:** the Elastic IP belongs to my account, not to the server, so I can move it. If `usms-web-01` breaks:

1. Start a new server from the golden AMI.
2. Run `aws ec2 associate-address --allocation-id <usms-web-eip> --instance-id <new-server> --allow-reassociation`.

Users reach the new server on the **same IP within seconds**, and DNS does not need to change. With an auto-assigned IP this is not possible, because the new server would get a different address.

## 5. EBS volumes, snapshots and Availability Zones

- **An EBS volume is stored inside one AZ.** That is why it can only be attached to an instance in the same AZ.
- **A snapshot is stored in S3.** S3 keeps data across many AZs in the region, which is why a snapshot can be restored in any AZ.

**What this means:** if `us-east-1a` goes down, `usms-web-data-vol` goes down with it. To survive the loss of one AZ:

- take regular snapshots, so the data can be restored in another AZ,
- keep golden AMIs, so new servers can start in any AZ,
- run servers in at least two AZs,
- keep important data in services that copy it across AZs, such as S3 or RDS Multi-AZ.

## 6. Were the six checks in Step 14 enough?

**No, they are not an adequate substitute.** They were the best we could do on Floci.

The six checks prove the **network path is open**: the instance is running, there is a route to the internet gateway, the gateway is attached, the security group allows port 80, there is a public IP, and the NACL allows it. But they only read AWS settings. They cannot see **inside the server**.

**The fault they cannot detect is a problem inside the instance or the application.** For example:

- the user-data script failed and nginx was never installed,
- nginx crashed or uses the wrong port,
- a firewall inside the operating system blocks port 80,
- the app returns an error page.

All six checks would still pass, but users would see nothing. Only a real request, like `curl http://<ip>/health.json`, can catch this.

## 7. Differences between usms-web-01 and usms-db-01

**Same for both:** `t3.micro`, same AMI, same key pair, same AZ (`us-east-1a`), same VPC.

| Difference | usms-web-01 | usms-db-01 | Belongs to |
|---|---|---|---|
| Name / Tier tag | `usms-web-01`, web | `usms-db-01`, data | Instance |
| Security group | `usms-app-sg` (port 80) | `usms-db-sg` (port 5432) | Instance |
| Instance profile | `usms-ec2-app-profile` | none | Instance |
| User data | `user-data.sh` | none | Instance |
| Elastic IP | `usms-web-eip` | none | Instance |
| Extra EBS volume | `usms-web-data-vol` | none | Instance |
| Private IP range | `10.0.1.0/24` | `10.0.3.0/24` | Subnet (the IP itself is the instance's) |
| Subnet | `usms-public-subnet-a` | `usms-private-subnet-a` | Subnet |
| Auto-assign public IP | on | off | Subnet |
| Route to the internet | internet gateway | NAT gateway (outbound only) | Subnet (its route table) |
| Network ACL | default NACL | `usms-private-nacl` | Subnet |

**VPC level:** there are **no** differences. Both use the same VPC, CIDR `10.0.0.0/16`, internet gateway and NAT gateway.

**Main point:** the database is private mainly because of the **subnet** it is in (no internet gateway route, no public IP). Its security group adds a second layer of protection.
