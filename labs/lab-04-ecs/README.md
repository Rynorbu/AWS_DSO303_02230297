
### Step 1 - Resume the environment and load three env files

![alt text](assets/1.png)

### Step 2 - Confirm Labs 2 and 3 are still intact


### Step 3 - Probe what this Floci build actually supports

![alt text](assets/3.png)

### Step 4 - Create the ECS cluster, as the developer role

#### Command - part 1, assume the role

![alt text](assets/4.png)

#### Command - part 2, create the cluster

![alt text](assets/4.1.png)

### Command - part 3, restore your normal identity

![alt text](assets/4.2.png)

#### Verify

![alt text](assets/4.3.png)

### Step 5 - Create the log group the tasks will write to

![alt text](assets/5.png)

### Step 6 - Create the task execution role

### Command - part 1, the trust policy

![alt text](assets/6.png)

### Command - part 2, create the role

![alt text](assets/6.1.png)

### Command - part 3, the permissions it needs, written as least privilege

![alt text](assets/6.2.png)

### Verify

![alt text](assets/6.3.png)

### Step 7 - Create the task role, and reuse Lab 1's policy on it

![alt text](assets/7.png)

![alt text](assets/7.1.png)

![alt text](assets/7.2.png)

### Step 8 - Create the enrolment security group, sourced from the web tier's group

![alt text](assets/8.png)

![alt text](assets/8.1.png)

### Step 9 - Write and register the task definition

#### Command - part 1, write the document

![alt text](assets/9.png)

#### Command - part 2, register it

![alt text](assets/9.1.png)

### Step 10 - Create the service in Lab 2's private subnets

![alt text](assets/10.png)

![alt text](assets/10.1.png)

### Step 11 - Read the service back, and learn the four numbers

![alt text](assets/11.png)

![alt text](assets/11.1.png)

### Your turn 


### Step 12 - Write configs/lab-04.env

![alt text](assets/12.png)

![alt text](assets/12.1.png)

### Step 13 - Commit

#### Command - part 1, look before you add

![alt text](assets/13.png)

#### Command - part 2, commit

![alt text](assets/13.1.png)

### Verification

![alt text](assets/verification.png)