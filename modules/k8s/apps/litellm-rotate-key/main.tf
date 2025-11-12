terraform {}

variable "name" {
  type = string
  validation {
    condition     = length(var.name) > 0
    error_message = "Name must not be empty"
  }
}

variable "namespace" {
  type = string
  validation {
    condition     = length(var.namespace) > 0
    error_message = "Namespace must not be empty"
  }
}

variable "role_labels" {
  type    = map(string)
  default = {}
}

variable "role_annotations" {
  type    = map(string)
  default = {}
}

variable "service_account_labels" {
  type    = map(string)
  default = {}
}

variable "role_binding_labels" {
  type    = map(string)
  default = {}
}

variable "role_binding_annotations" {
  type    = map(string)
  default = {}
}

variable "service_account_annotations" {
  type    = map(string)
  default = {}
}

variable "litellm_deployment_name" {
  type = string
  validation {
    condition     = length(var.litellm_deployment_name) > 0
    error_message = "LiteLLM deployment name must not be empty"
  }
}

variable "litellm_secret_key_name" {
  type = string
  validation {
    condition     = length(var.litellm_secret_key_name) > 0
    error_message = "LiteLLM secret key name must not be empty"
  }
}

module "role" {
  source = "../../objects/role"

  name        = var.name
  namespace   = var.namespace
  labels      = var.role_labels
  annotations = var.role_annotations
  rules = [{
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [var.litellm_secret_key_name]
    verbs          = ["get", "create", "update", "patch"]
    }, {
    api_groups     = ["apps", "extensions"]
    resources      = ["deployments"]
    resource_names = [var.litellm_deployment_name]
    verbs          = ["get", "patch"]
  }]
}

module "serviceaccount" {
  source = "../../objects/serviceaccount"

  name        = var.name
  namespace   = var.namespace
  labels      = var.service_account_labels
  annotations = var.service_account_annotations
}

module "rolebinding" {
  source = "../../objects/rolebinding"

  name        = var.name
  namespace   = var.namespace
  labels      = var.role_binding_labels
  annotations = var.role_binding_annotations
  # Use var.name directly as modules don't expose name outputs, only manifests
  role_ref = {
    name = var.name
  }
  subjects = [{
    # Added kind field for proper Kubernetes RBAC subject specification
    kind      = "ServiceAccount"
    name      = var.name
    namespace = var.namespace
  }]
}

# Output manifests for validation and debugging
output "role_manifest" {
  value = module.role.manifest
}

output "serviceaccount_manifest" {
  value = module.serviceaccount.manifest
}

output "rolebinding_manifest" {
  value = module.rolebinding.manifest
}