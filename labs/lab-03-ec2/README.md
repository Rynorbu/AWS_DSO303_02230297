

### Step 1: Resume the environment and load three env files

The lab consumes the value of the two previous labs. So, firstly, I have resumed the environment and loaded the three env files.

Started the floci environment.

![alt text](assets/1.png)

![alt text](assets/1.1.png)

![alt text](assets/1.2.png)

### Step 2: Confirm Part A's network is intact

Before bulding on the network, I have checked if it is still there and still correct, using the verification script from Lab 2.

![alt text](assets/2.png)

### Step 3: Choose an AMI

![alt text](assets/3.png)

![alt text](assets/3.1.png)

### Step 4: Create the key pair and store the private key safely

![alt text](assets/4.png)

![alt text](assets/4.1.png)

### Step 5: Prove the private key is git-ignored

![alt text](assets/5.png)

![alt text](assets/5.1.png)

### Step 6: Write the user-data bootstrap script

![alt text](assets/6.png)

### Step 7: Generate a request skeleton and fill it in

Command: part 1, look at the shape

![alt text](assets/7.png)

Command: part 2, write the request we actually want

![alt text](assets/7.1.png)

### Step 8: Launch the USMS web server

![alt text](assets/8.png)

### Step 9: Wait for the instance to reach running

![alt text](assets/9.png)

![alt text](assets/9.1.png)


### Step 10: Read the instance back and understand the fields

![alt text](assets/10.png)

### Step 11: Trace the permission chain from the instance to the policy

![alt text](assets/11.png)


### Step 12: Prove the user data actually arrived


### Step 13: Give the web server a stable public address

![alt text](assets/13.png)

Verify

![alt text](assets/13.1.png)

### Step 14: Test the application

![alt text](assets/14.png)

Command: fallback, prove every link in the chain

![alt text](assets/14.1.png)

### Step 15: Create and attach a data volume

![alt text](assets/15.png)

Verify

![alt text](assets/15.1.png)

### Step 16: Launch the database-tier instance into the private subnet


![alt text](assets/16.png)

### Step 17: Prove the two tiers are wired the way you think

![alt text](assets/17.png)

### Step 18: Stop and start the web server, and watch which address moves

![alt text](assets/18.png)  

### Step 19: Prove persistence across a restart

#### Part 1: record the state

![alt text](assets/19.png)

#### Part 2: restart Floci

![alt text](assets/19.1.png)

#### Part 3: read it back by tag, not by variable

![alt text](assets/19.2.png)

### Step 20: Create an AMI from the configured instance

![alt text](assets/20.png)

### Step 21: Audit what this lab created

![alt text](assets/21.png)

### Step 21 "Your turn": exposure report

![alt text](assets/your_turn_21.png)

### Step 22: Write configs/lab-03.env

