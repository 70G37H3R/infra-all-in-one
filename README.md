# K3s Kubernetes Cluster on AWS — Terraform + Ansible + Helm

A fully automated pipeline to provision a two-node K3s Kubernetes cluster on AWS. Terraform provisions the infrastructure, Ansible installs K3s and deploys the Helm chart, and a FastAPI app measures TCP latency between the two nodes.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                        AWS (us-east-1)                  │
│                                                         │
│   VPC: 10.0.0.0/16                                      │
│                                                         │
│   ┌─────────────────┐     ┌─────────────────┐           │
│   │  public-subnet  │     │  public-subnet-2│           │
│   │  10.0.1.0/24    │     │  10.0.2.0/24    │           │
│   │  us-east-1a     │     │  us-east-1b     │           │
│   │                 │     │                 │           │
│   │  vm-0           │     │  vm-1           │           │
│   │                 │     │                 │           │
│   │  K3s Server     │────▶│  K3s Agent      │           │
│   │  Control Plane  │     │  Worker Node    │           │
│   └─────────────────┘     └─────────────────┘           │
│            │                                            │
│   Internet Gateway                                      │
└─────────────────────────────────────────────────────────┘
```

**Provisioning flow:**

```
Terraform → AWS EC2 → Ansible → K3s cluster → Helm → Application
```

---

## Project Structure

```
.
├── aws/
│   └── assume-role.sh             # Fetches temporary STS credentials
├── ansible/
│   ├── ansible.cfg                # SSH config, key path, pipelining
│   ├── inventory.ini              # Node private IPs
│   └── provisioning.yaml          # 3 plays: K3s server → worker → Helm deploy
├── terraform/
│   ├── main.tf                    # VPC, subnets, IGW, security group, EC2
│   ├── variables.tf               # instance_type variable
│   ├── terraform.tfvars.dev       # Dev: t3.micro
│   └── terraform.tfvars.prod      # Prod: t3.medium
├── application/
│   ├── main.py                    # FastAPI app — TCP latency monitor
│   ├── Dockerfile                 # Multi-stage build
│   └── requirements.txt
└── helm/
    ├── Chart.yaml
    ├── values.yaml                # Base values (image, nodeSelector, ingress…)
    ├── values-dev.yaml            # Dev overrides (targetHost, tcpPort)
    ├── values-prod.yaml           # Prod overrides (targetHost, tcpPort)
    └── templates/
        ├── deployment.yaml        # 1 replica, pinned to vm-0 via nodeSelector
        ├── service.yaml           # ClusterIP — latency-monitor-service
        └── ingress.yaml           # Traefik ingress: /latency /metrics /health
```

---

## Provisioning and Deployment

### Step 1 — IAM Setup

**Create the IAM role** (`DevOps-Terraform-Role`) with `AdministratorAccess` and set this trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<ACCOUNT_ID>:user/<YOUR_IAM_USER>"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Grant the IAM user permission to assume that role:**

```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/DevOps-Terraform-Role"
}
```

**Configure the local AWS CLI profile:**

```bash
aws configure --profile devops-user
```

---

### Step 2 — Assume the Role

Source the script before any Terraform commands to export short-lived credentials:

```bash
source aws/assume-role.sh
```

This calls `sts:AssumeRole` and exports `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` into your current shell. Credentials expire after 1 hour — re-run if you hit auth errors.

**Advantages**
`devops-user` only has permission to call `sts:AssumeRole` — nothing else. If those credentials leak, the blast radius is zero. The temporary tokens expire within the hour, and all Terraform activity is logged in CloudTrail under the session name `terraform-session`.

---

### Step 3 — Provision Infrastructure with Terraform

Pick the var file for the target environment:

| Environment | File | Instance type |
|-------------|------|---------------|
| Dev | `terraform.tfvars.dev` | `t3.micro` |
| Prod | `terraform.tfvars.prod` | `t3.medium` |

```bash
cd terraform

terraform init
terraform plan -var-file="terraform.tfvars.dev" -out=tfplan
terraform apply "tfplan"
```

Get the public IPs after apply:

```bash
terraform output k3s_public_ips
```

**Security group rules:**

| Port | Source | Purpose |
|------|--------|---------|
| 22 | Your IP only | SSH |
| 80 | `0.0.0.0/0` | HTTP ingress via Traefik |
| 6443 | Your IP only | K3s API server |
| All | `10.0.0.0/16` | Internal VPC — K3s node-to-node communication |
| All egress | `0.0.0.0/0` | apt installs, K3s binary, container image pulls |

---

### Step 4 — Prepare vm-0

SSH in and create the working directories:

```bash
ssh -i terraform-devops.pem ubuntu@<vm-0-public-ip>
mkdir -p ~/k3s-ansible
```

Copy files from your local machine:

```bash
scp -i terraform-devops.pem \
  terraform-devops.pem \
  ansible/inventory.ini \
  ansible/provisioning.yaml \
  ansible/ansible.cfg \
  ubuntu@<vm-0-public-ip>:~/k3s-ansible/

scp -i terraform-devops.pem -r helm/ ubuntu@<vm-0-public-ip>:~/helm/
```

Update `~/k3s-ansible/inventory.ini` with private IPs:

```ini
[master]
vm-0 ansible_host=10.0.1.168 ansible_user=ubuntu

[worker]
vm-1 ansible_host=10.0.2.133 ansible_user=ubuntu
```

---

### Step 5 — Run the Ansible Playbook

```bash
cd ~/k3s-ansible
chmod 400 terraform-devops.pem

# Verify connectivity
ansible all -i inventory.ini -m ping

# Deploy — dev environment
ansible-playbook -i inventory.ini provisioning.yaml -e helm_values_file=values-dev.yaml

# Deploy — prod environment
ansible-playbook -i inventory.ini provisioning.yaml -e helm_values_file=values-prod.yaml
```

The playbook runs 3 plays in sequence:

| Play | Target | Actions |
|------|--------|---------|
| 1 — Install K3s server | master | Installs K3s, waits for node token |
| 2 — Join worker | worker | Installs K3s agent, joins the cluster |
| 3 — Deploy Helm chart | master | Waits for all nodes Ready → `helm upgrade --install` → verifies pod Running |

Default `helm_values_file` is `values-dev.yaml`. Override with `-e helm_values_file=values-prod.yaml` for prod.

---

### Step 6 — Verify the Cluster

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl get nodes
```

Expected (node names = EC2 private DNS hostnames):

```
NAME              STATUS   ROLES                  AGE   VERSION
ip-10-0-1-168     Ready    control-plane,master   Xm    v1.x.x+k3s1
ip-10-0-2-133     Ready    <none>                 Xm    v1.x.x+k3s1
```

Check Traefik (built into K3s):

```bash
kubectl get pods -n kube-system | grep traefik
```

---

### Step 7 — Verify the Helm Deployment

```bash
# Release status
helm list -n application

# Pod running on vm-0
kubectl get pods -n application -o wide

# Ingress
kubectl get ingress -n application
```

Expected pod:

```
NAME               READY   STATUS    NODE
latency-monitor    1/1     Running   ip-10-0-1-168
```

**Access via Ingress:**

```bash
# Add to /etc/hosts
echo "<vm-0-public-ip>  latency-monitor.local" | sudo tee -a /etc/hosts

curl http://latency-monitor.local/latency
curl http://latency-monitor.local/metrics
curl http://latency-monitor.local/health
```

---

## Latency Monitor App

FastAPI service running on vm-0. Every `MEASURE_INTERVAL` seconds it opens a TCP connection to vm-1 and measures how long the handshake takes — the programmatic equivalent of `telnet <host> <port>`.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TARGET_HOST` | `10.0.2.133` | Private IP of vm-1 |
| `TCP_PORT` | `22` | Port to test |
| `MEASURE_INTERVAL` | `30` | Seconds between measurements |

### Run locally with Docker

```bash
docker build -t latency-monitor:latest ./application
docker run -p 8000:8000 -e TARGET_HOST=10.0.2.133 latency-monitor:latest
```
OR
```bash
docker run -p 8000:8000 -e TARGET_HOST=10.0.2.133 cod3rdock3r/latency-monitor:v1.0

```
### Endpoints

#### `GET /latency` — JSON

```bash
curl http://latency-monitor.local/latency
```

```json
{
  "collected_at": "2025-01-01T12:00:00+00:00",
  "target_host": "10.0.2.133",
  "tcp_port": 22,
  "interval_seconds": 30,
  "tcp": {
    "status": "ok",
    "port": 22,
    "latency_ms": 0.784
  }
}
```

#### `GET /metrics` — Prometheus format

```bash
curl http://latency-monitor.local/metrics
```

```
# HELP tcp_latency_ms TCP handshake latency to the target host (milliseconds)
# TYPE tcp_latency_ms gauge
tcp_latency_ms{host="10.0.2.133",port="22"} 0.784

# HELP tcp_up 1 if the TCP port is reachable, 0 otherwise
# TYPE tcp_up gauge
tcp_up{host="10.0.2.133",port="22"} 1
```

#### `GET /health`

```bash
curl http://latency-monitor.local/health
# {"status":"ok"}
```

### Interpreting the numbers

| Metric | What it means |
|--------|--------------|
| `tcp.latency_ms` < 1ms | Normal — both nodes are in the same VPC |
| `tcp.latency_ms` rising | Network pressure or CPU saturation on vm-1 |
| `tcp.status = timeout` | vm-1 unreachable — check security group internal VPC rule |
| `tcp.status = connection_refused` | Port is closed on vm-1 |
| `tcp_up = 0` | Port is not reachable — check the node and security group |

---

## Assumptions, Limitations, and Tradeoffs

**Assumptions**
- The Helm chart must be manually copied to `/home/ubuntu/helm/` on vm-0 before running the playbook.

**Limitations**
- **Single control plane.** vm-0 is the only K3s server. If it goes down, the API is unreachable and no new workloads can be scheduled.
- **No persistent storage.** Data lives on the instance disk. EBS or EFS would be needed for stateful workloads.

**Tradeoffs**
- Public subnets avoid the ~$32/month NAT Gateway cost. The security group locks down all sensitive ports to a single IP.
- `helm upgrade --install` makes the playbook idempotent — re-running upgrades instead of failing on an existing release.
