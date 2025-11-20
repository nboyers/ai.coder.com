# Terraform Backend Configuration

## Security Notice

This directory uses remote S3 backend for state management, but **backend configuration files are gitignored** to prevent leaking AWS account IDs and other sensitive information.

## Local Setup

1. **Get backend configuration from teammate** or **retrieve from AWS**:
   ```bash
   # Get S3 bucket name (it contains the account ID)
   aws s3 ls | grep terraform-state

   # Get DynamoDB table name
   aws dynamodb list-tables --query 'TableNames[?contains(@, `terraform-lock`)]'
   ```

2. **Create backend configuration** for each module:

   Each Terraform module needs a `backend.tf` file (this file is gitignored). Create it manually:

   ```bash
   cd infra/aws/us-east-2/vpc  # or any other module
   ```

   Create `backend.tf`:
   ```hcl
   terraform {
     backend "s3" {
       bucket         = "YOUR-BUCKET-NAME-HERE"
       key            = "us-east-2/vpc/terraform.tfstate"  # Update path per module
       region         = "us-east-2"
       dynamodb_table = "YOUR-TABLE-NAME-HERE"
       encrypt        = true
     }
   }
   ```

   **Important**: Update the `key` path for each module:
   - VPC: `us-east-2/vpc/terraform.tfstate`
   - EKS: `us-east-2/eks/terraform.tfstate`
   - ACM: `us-east-2/acm/terraform.tfstate`
   - etc.

3. **Initialize Terraform**:
   ```bash
   terraform init
   ```

## GitHub Actions Setup

GitHub Actions uses secrets to configure the backend securely. Required secrets:

1. `TF_STATE_BUCKET` - S3 bucket name
2. `TF_STATE_LOCK_TABLE` - DynamoDB table name
3. `AWS_ROLE_ARN` - IAM role ARN for OIDC authentication

These are configured in: Repository Settings > Secrets and variables > Actions

## Alternative: Using Backend Config File

Instead of creating backend.tf, you can use a config file:

1. Create `backend.conf` (gitignored):
   ```
   bucket         = "YOUR-BUCKET-NAME"
   dynamodb_table = "YOUR-TABLE-NAME"
   region         = "us-east-2"
   encrypt        = true
   ```

2. Initialize with:
   ```bash
   terraform init -backend-config=backend.conf -backend-config="key=us-east-2/vpc/terraform.tfstate"
   ```

## Why This Approach?

- **Security**: Account IDs and resource names aren't committed to Git
- **Flexibility**: Each developer/environment can use different backends
- **Compliance**: Prevents accidental exposure of infrastructure details
- **Best Practice**: Follows AWS security recommendations

## Migrating Existing State

If you have local state to migrate:

```bash
terraform init -migrate-state
```

Terraform will prompt to copy existing state to the remote backend.
