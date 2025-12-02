# Coder Demo Environment (coderdemo.io)

Welcome to the Coder Demo Environment's Github repository!

This project powers ["coderdemo.io"](https://coderdemo.io), a production-grade, multi-region demonstration environment showcasing Coder's cloud development capabilities, workspace proxies, and global deployment patterns.

---

## Getting Started

### Accessing the Deployment:

Get Started Here 👉 [https://coderdemo.io](https://coderdemo.io)

**Login Flow**

1. Click "Sign in with GitHub"
2. Authorize the Coder Demo GitHub App
3. Start creating workspaces in your preferred region!

**Available Regions:**

- 🇺🇸 **US East (Ohio)** - Primary deployment with database
- 🇺🇸 **US West (Oregon)** - Secondary server + workspace proxy
- 🇪🇺 **EU West (London)** - Workspace proxy

> [!NOTE] This is a demo environment. For production Coder deployments, refer to the [official Coder documentation](https://coder.com/docs).

---

## Architecture Overview

This deployment implements a **hub-and-spoke architecture** across three AWS regions:

### Hub Region: us-east-2 (Ohio)

The primary region containing foundational, non-repeatable infrastructure:

- **Central Database**: Aurora Serverless v2 PostgreSQL cluster (shared by all regions)
- **Terraform Backend**: S3 bucket and DynamoDB table for state management
- **Container Registry**: ECR for custom images
- **Primary VPC**: Custom VPC with peering to spoke regions
- **Primary Coder Server**: Main deployment handling authentication and control plane
- **Additional Services**: Redis, LiteLLM, and custom applications

### Spoke Regions: us-west-2 (Oregon) & eu-west-2 (London)

Repeatable regional infrastructure for workspace proxies:

- **Workspace Proxies**: Low-latency access to workspaces
- **EKS Clusters**: Regional Kubernetes clusters with Karpenter autoscaling
- **Route53**: Regional DNS records for proxy endpoints
- **AWS ACM**: Regional SSL/TLS certificates

```
                    ┌─────────────────────────────────┐
                    │   us-east-2 (Primary Hub)       │
                    │                                 │
                    │  ┌─────────────────────────┐   │
                    │  │   Coder Server          │   │
                    │  │   Aurora Serverless v2  │   │
                    │  │   Redis / ECR           │   │
                    │  └─────────────────────────┘   │
                    │                                 │
                    └────────────┬───────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
         ┌──────────▼──────────┐   ┌─────────▼──────────┐
         │  us-west-2 (Spoke)  │   │ eu-west-2 (Spoke)  │
         │                     │   │                    │
         │  ┌───────────────┐  │   │  ┌──────────────┐ │
         │  │ Coder Proxy   │  │   │  │ Coder Proxy  │ │
         │  │ Coder Server  │  │   │  │ Workspaces   │ │
         │  │ Workspaces    │  │   │  └──────────────┘ │
         │  └───────────────┘  │   │                    │
         └─────────────────────┘   └────────────────────┘
```

For detailed architecture documentation, see:

- [Multi-Region Deployment Guide](./docs/MULTI_REGION_DEPLOYMENT.md)
- [Infrastructure Best Practices](./docs/INFRASTRUCTURE_BEST_PRACTICES.md)
- [Architecture Diagram](./docs/ARCHITECTURE_DIAGRAM.md)

---

## How-To-Deploy

> [!WARNING]
> **Infrastructure Repeatability Notice**
>
> This environment is heavily opinionated towards AWS and uses a hub-and-spoke architecture:
>
> - **[`infra/aws/us-east-2`](./infra/aws/us-east-2)** - Primary hub region with foundational infrastructure (database, terraform backend, VPC, etc.). **This is NOT repeatable** - it's meant to be deployed once as your control plane.
> - **[`infra/aws/eu-west-2`](./infra/aws/eu-west-2)** - Clean spoke region example with workspace proxy only. **This IS repeatable** for adding new regions.
> - **[`infra/aws/us-west-2`](./infra/aws/us-west-2)** - Hybrid spoke region with both server and proxy deployments. Use this as a reference for redundant server deployments.
>
> When deploying to new regions, use `eu-west-2` as your template for workspace proxies.

### Deployment Overview

The infrastructure is deployed in layers:

1. **Foundation Layer** (us-east-2 only - deploy once)
   - Terraform backend (S3 + DynamoDB)
   - VPC with custom networking
   - Aurora Serverless v2 PostgreSQL database
   - ECR for container images
   - Redis for caching

2. **Compute Layer** (all regions)
   - EKS clusters with managed node groups
   - Karpenter for workspace autoscaling
   - VPC peering (for spoke regions to hub)

3. **Certificate & DNS Layer** (all regions)
   - AWS Certificate Manager (ACM) for SSL/TLS
   - Route53 for DNS management
   - Regional subdomains (e.g., `us-west-2.coderdemo.io`)

4. **Kubernetes Applications Layer** (all regions)
   - AWS Load Balancer Controller
   - AWS EBS CSI Driver
   - Karpenter node provisioner
   - Metrics Server
   - Cert Manager

5. **Coder Layer**
   - **Primary (us-east-2)**: Coder Server with database connection
   - **Spoke regions**: Coder Workspace Proxies connected to primary

### About the Infrastructure Modules

This repository provides reusable Terraform modules for deploying Coder on AWS:

#### Network Module: [`eks-vpc`](./modules/network/eks-vpc)

Creates an opinionated VPC designed for EKS and Coder workloads:

- Customizable public and private subnets across multiple AZs
- Internet Gateway for public access
- Cost-optimized NAT Gateway using [fck-nat](https://github.com/RaJiska/terraform-aws-fck-nat)
- Automatic routing configuration
- Subnet tagging for EKS and Karpenter integration

#### Compute Module: [`eks-cluster`](./modules/compute/cluster)

Creates a production-ready EKS cluster similar to [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html):

- Leverages the [AWS Managed Terraform EKS module](https://github.com/terraform-aws-modules/terraform-aws-eks/tree/master)
- Pre-configured IAM roles and policies for:
  - [Karpenter](https://karpenter.sh/) - Node autoscaling
  - [AWS EBS CSI Driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver) - Persistent volumes
  - [AWS Load Balancer Controller](https://github.com/kubernetes-sigs/aws-load-balancer-controller) - Ingress management
  - [Coder External Provisioner](https://coder.com/docs/admin/provisioners) - Workspace provisioning
  - [Amazon Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html) - AI capabilities
- IRSA (IAM Roles for Service Accounts) configuration
- Node group with custom launch templates

#### Kubernetes Bootstrap Modules: [`modules/k8s/bootstrap/`](./modules/k8s/bootstrap/)

Helm-based Kubernetes application deployments:

- **[`lb-controller`](./modules/k8s/bootstrap/lb-controller)** - AWS Load Balancer Controller
- **[`ebs-controller`](./modules/k8s/bootstrap/ebs-controller)** - AWS EBS CSI Driver
- **[`metrics-server`](./modules/k8s/bootstrap/metrics-server)** - Kubernetes Metrics Server
- **[`karpenter`](./modules/k8s/bootstrap/karpenter)** - Karpenter autoscaler with NodePools
- **[`cert-manager`](./modules/k8s/bootstrap/cert-manager)** - Certificate management
- **[`coder-server`](./modules/k8s/bootstrap/coder-server)** - Primary Coder deployment
- **[`coder-proxy`](./modules/k8s/bootstrap/coder-proxy)** - Workspace proxy deployments

---

## Deployment Guide

### Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.9.0
- kubectl
- Helm 3.x
- GitHub OAuth App credentials (for authentication)

### Step 1: Deploy Foundation Infrastructure (us-east-2 only)

> [!IMPORTANT]
> Only deploy this once for your entire multi-region setup.

```bash
cd infra/aws/us-east-2

# 1. Create Terraform backend
cd terraform-backend
terraform init
terraform apply
cd ..

# 2. Create VPC
cd vpc
terraform init -backend-config=backend.hcl
terraform apply
cd ..

# 3. Deploy EKS cluster
cd eks
terraform init -backend-config=backend.hcl
terraform apply
cd ..

# 4. Deploy Aurora Serverless v2 database
cd rds
terraform init -backend-config=backend.hcl
terraform apply
cd ..

# 5. Set up Route53 and ACM for primary domain
cd route53
terraform init -backend-config=backend.hcl
terraform apply
cd ..

cd acm
terraform init -backend-config=backend.hcl
terraform apply
cd ..
```

### Step 2: Deploy Kubernetes Applications (us-east-2)

```bash
cd infra/aws/us-east-2/k8s

# Update kubeconfig
aws eks update-kubeconfig --region us-east-2 --name coderdemo

# Deploy in order (each depends on previous)
cd lb-controller && terraform init -backend-config=backend.hcl && terraform apply && cd ..
cd ebs-controller && terraform init -backend-config=backend.hcl && terraform apply && cd ..
cd metrics-server && terraform init -backend-config=backend.hcl && terraform apply && cd ..
cd karpenter && terraform init -backend-config=backend.hcl && terraform apply && cd ..
cd cert-manager && terraform init -backend-config=backend.hcl && terraform apply && cd ..

# Deploy Coder Server
cd coder-server && terraform init -backend-config=backend.hcl && terraform apply && cd ..

# Deploy Coder Workspace Provisioner
cd coder-ws && terraform init -backend-config=backend.hcl && terraform apply && cd ..
```

### Step 3: Deploy Spoke Regions (repeatable)

For each additional region (use `eu-west-2` as template):

```bash
# Example: Deploy to eu-west-2
cd infra/aws/eu-west-2

# 1. Deploy EKS cluster
cd eks
terraform init -backend-config=backend.hcl
terraform apply
cd ..

# 2. Deploy Kubernetes applications (same order as us-east-2)
cd k8s
aws eks update-kubeconfig --region eu-west-2 --name coderdemo-euw2

cd lb-controller && terraform init -backend-config=backend.hcl && terraform apply && cd ..
cd ebs-controller && terraform init -backend-config=backend.hcl && terraform apply && cd ..
cd metrics-server && terraform init -backend-config=backend.hcl && terraform apply && cd ..
cd karpenter && terraform init -backend-config=backend.hcl && terraform apply && cd ..
cd cert-manager && terraform init -backend-config=backend.hcl && terraform apply && cd ..

# 3. Deploy Coder Workspace Proxy
cd coder-proxy && terraform init -backend-config=backend.hcl && terraform apply && cd ..

# 4. Deploy Coder Workspace Provisioner
cd coder-ws && terraform init -backend-config=backend.hcl && terraform apply && cd ..
```

### Step 4: Configure DNS and Certificates

Each region requires:

1. Route53 DNS records pointing to the regional load balancer
2. ACM certificate for the regional subdomain
3. TLS certificate configuration in Coder proxy/server

See the region-specific configurations in:

- `infra/aws/us-east-2/route53/`
- `infra/aws/us-west-2/route53/`
- `infra/aws/us-west-2/acm/`

---

## Configuration

### Terraform Variables

Each deployment requires a `terraform.tfvars` file (gitignored for security). Key variables include:

#### EKS Variables

```hcl
cluster_name    = "coderdemo"
cluster_region  = "us-east-2"
cluster_profile = "your-aws-profile"
```

#### Coder Variables

```hcl
coder_access_url          = "https://coderdemo.io"
coder_wildcard_access_url = "*.coderdemo.io"
addon_version             = "2.27.1"  # Coder version
```

#### Database (us-east-2 only)

```hcl
coder_db_secret_url = "postgres://user:pass@host:5432/coder?sslmode=require"
```

#### Authentication

```hcl
# GitHub OAuth
coder_oauth_secret_client_id     = "your-github-oauth-client-id"
coder_oauth_secret_client_secret = "your-github-oauth-secret"

# GitHub External Auth (for workspace git operations)
coder_github_external_auth_secret_client_id     = "your-github-app-id"
coder_github_external_auth_secret_client_secret = "your-github-app-secret"
```

#### SSL/TLS Configuration

```hcl
# Using AWS ACM (recommended)
kubernetes_create_ssl_secret = false
kubernetes_ssl_secret_name   = "coder-tls"
acme_registration_email      = "admin@coderdemo.io"
```

### Backend Configuration

Each region uses S3 for Terraform state. Create a `backend.hcl` file:

```hcl
bucket         = "your-terraform-state-bucket"
key            = "path/to/state/terraform.tfstate"
region         = "us-east-2"
dynamodb_table = "your-terraform-locks-table"
encrypt        = true
profile        = "your-aws-profile"
```

---

## Multi-Region Architecture Details

### Database Strategy

This deployment uses a **centralized database** approach:

- Aurora Serverless v2 PostgreSQL in us-east-2
- All regions connect to the same database over VPC peering
- Benefits: Simplified data consistency, no replication complexity
- Trade-offs: All regions depend on us-east-2 availability

For production high-availability requirements, consider:

- Aurora Global Database for multi-region read replicas
- Active-active deployments with database replication
- Regional database failover strategies

See [Multi-Region Deployment Guide](./docs/MULTI_REGION_DEPLOYMENT.md) for more details.

### Workspace Proxy Strategy

Workspace proxies provide:

- **Low-latency connections** to workspaces in remote regions
- **Reduced bandwidth costs** by keeping traffic regional
- **Improved user experience** for global teams

Each proxy:

1. Registers with the primary Coder server (us-east-2)
2. Receives a session token for authentication
3. Proxies workspace connections without database access
4. Can run workspace provisioners locally

### Network Architecture

- **VPC Peering**: Spoke regions peer with hub region for database access
- **NAT Strategy**: Cost-optimized fck-nat for outbound internet access
- **Load Balancers**: NLB for Coder, ALB for other services
- **DNS**: Regional subdomains route to closest workspace proxy

---

## Monitoring and Observability

> [!NOTE]
> Observability stack configuration is in progress.

Planned integrations:

- Prometheus for metrics collection
- Grafana for visualization
- CloudWatch for AWS resource monitoring
- Coder built-in metrics and health endpoints

---

## Security Considerations

### Secrets Management

- **Database credentials**: Stored in terraform.tfvars (gitignored)
- **OAuth credentials**: Stored in terraform.tfvars (gitignored)
- **TLS certificates**: Managed by AWS ACM
- **Kubernetes secrets**: Created by Terraform, stored in etcd

For production, consider:

- AWS Secrets Manager for credential rotation
- External Secrets Operator for Kubernetes
- HashiCorp Vault for centralized secret management

### Network Security

- Private subnets for all compute resources
- Security groups restricting traffic between tiers
- VPC peering for controlled cross-region access
- TLS encryption for all external endpoints

### IAM Best Practices

- IRSA (IAM Roles for Service Accounts) for pod-level permissions
- Least privilege principle for all IAM policies
- No long-lived credentials in pods
- Regular IAM policy audits

---

## Cost Optimization

Key strategies used in this deployment:

1. **Karpenter Autoscaling**: Scales nodes to zero when workspaces are idle
2. **Aurora Serverless v2**: Scales database capacity based on load
3. **fck-nat**: Open-source NAT solution (90% cheaper than AWS NAT Gateway)
4. **Spot Instances**: Karpenter uses spot for workspace nodes where appropriate
5. **Regional Resources**: Only deploy proxies in regions with active users

Estimated monthly costs:

- Hub region (us-east-2): $200-400/month base + per-workspace costs
- Spoke regions: $100-200/month base + per-workspace costs

See [Infrastructure Best Practices](./docs/INFRASTRUCTURE_BEST_PRACTICES.md) for detailed cost analysis.

---

## Troubleshooting

### Common Issues

**EKS cluster creation fails**

- Verify IAM permissions for EKS and VPC operations
- Check VPC CIDR doesn't conflict with existing networks
- Ensure sufficient EIPs available in the region

**Karpenter not scaling nodes**

- Verify Karpenter controller has IRSA permissions
- Check NodePool configurations in `k8s/karpenter/`
- Review Karpenter logs: `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter`

**Coder proxy not connecting**

- Verify proxy token is correctly configured
- Check network connectivity from proxy to primary server
- Review NLB health checks and target group status

**Database connection failures**

- Verify security group allows traffic from EKS nodes
- Check VPC peering routes are configured
- Confirm database URL includes `?sslmode=require`

### Useful Commands

```bash
# Check EKS cluster status
aws eks describe-cluster --name coderdemo --region us-east-2

# Get kubeconfig
aws eks update-kubeconfig --name coderdemo --region us-east-2

# View Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Check Coder server logs
kubectl logs -n coder -l app.kubernetes.io/name=coder -f

# List all Karpenter nodes
kubectl get nodes -l karpenter.sh/initialized=true

# Check workspace proxy status
kubectl get pods -n coder-proxy
```

---

## Contributing

This repository represents a production demo environment. For general Coder questions or contributions, please visit:

- [Coder GitHub](https://github.com/coder/coder)
- [Coder Documentation](https://coder.com/docs)
- [Coder Community Discord](https://coder.com/chat)

---

## License

This infrastructure code is provided as-is for reference purposes. Refer to individual component licenses:

- [Coder License](https://github.com/coder/coder/blob/main/LICENSE)
- [Terraform License](https://github.com/hashicorp/terraform/blob/main/LICENSE)
- [AWS Provider License](https://github.com/hashicorp/terraform-provider-aws/blob/main/LICENSE)

---

## Additional Resources

- [Coder Documentation](https://coder.com/docs)
- [Coder Template Examples](https://github.com/coder/coder/tree/main/examples/templates)
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter Documentation](https://karpenter.sh/docs/)
- [Multi-Region Deployment Guide](./docs/MULTI_REGION_DEPLOYMENT.md)
- [Infrastructure Best Practices](./docs/INFRASTRUCTURE_BEST_PRACTICES.md)

---

**Built with ❤️ by the Coder team**
