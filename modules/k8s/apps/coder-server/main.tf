terraform {
  required_providers {
    local = {
      source = "hashicorp/local"
    }
  }
}

variable "path" {
  type = string
  validation {
    condition     = length(var.path) > 0
    error_message = "Path must not be empty"
  }
}

variable "namespace" {
  type = string
  validation {
    condition     = length(var.namespace) > 0
    error_message = "Namespace must not be empty"
  }
}

variable "image_repo" {
  type = string
  validation {
    condition     = length(var.image_repo) > 0
    error_message = "Image repository must not be empty"
  }
}

variable "image_tag" {
  type = string
  validation {
    condition     = length(var.image_tag) > 0
    error_message = "Image tag must not be empty"
  }
}

variable "image_pull_policy" {
  type    = string
  default = "IfNotPresent"
}

variable "image_pull_secrets" {
  type    = list(string)
  default = []
}

variable "coder_helm_chart_ver" {
  type = string
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.coder_helm_chart_ver))
    error_message = "Helm chart version must be in semver format (e.g., 2.23.0)"
  }
}

variable "primary_access_url" {
  type = string
  validation {
    condition     = can(regex("^https?://", var.primary_access_url))
    error_message = "Primary access URL must start with http:// or https://"
  }
}

variable "service_account_name" {
  type = string
  validation {
    condition     = length(var.service_account_name) > 0
    error_message = "Service account name must not be empty"
  }
}

variable "service_account_labels" {
  type    = map(string)
  default = {}
}

variable "service_account_annotations" {
  type    = map(string)
  default = {}
}

variable "extern_prov_service_account_name" {
  type    = string
  default = "coder"
}

variable "extern_prov_service_account_annotations" {
  type    = map(string)
  default = {}
}

variable "replica_count" {
  type = number
  # Changed from 0 to 1 to ensure at least one Coder server pod runs by default
  default = 1
  validation {
    condition     = var.replica_count >= 1
    error_message = "Replica count must be at least 1 to ensure service availability"
  }
}

variable "env_vars" {
  type    = map(string)
  default = {}
}

variable "resource_requests" {
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "2000m"
    memory = "4Gi"
  }
}

# https://coder.com/docs/admin/infrastructure/validated-architectures/1k-users#coderd-nodes
# 4 CPU's for other pods on the node (e.g. ebs-csi, kube-proxy)
variable "resource_limits" {
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "4000m"
    memory = "8Gi"
  }
}

variable "node_selector" {
  type    = map(string)
  default = {}
}

variable "tolerations" {
  type = list(object({
    key      = string
    operator = optional(string, "Equal")
    value    = string
    effect   = optional(string, "NoSchedule")
  }))
  default = []
}

variable "topology_spread_constraints" {
  type = list(object({
    max_skew           = number
    topology_key       = string
    when_unsatisfiable = optional(string, "DoNotSchedule")
    label_selector = object({
      match_labels = map(string)
    })
    match_label_keys = list(string)
  }))
  default = []
}

variable "pod_anti_affinity_preferred_during_scheduling_ignored_during_execution" {
  type = list(object({
    weight = number
    pod_affinity_term = object({
      label_selector = object({
        match_labels = map(string)
      })
      topology_key = string
    })
  }))
  default = []
}

module "kustomization" {
  source    = "../../objects/kustomization"
  namespace = var.namespace
  helm_charts = [{
    name         = "coder"
    release_name = "coder-v2"
    repo         = "https://helm.coder.com/v2"
    namespace    = var.namespace
    include_crds = true
    version      = var.coder_helm_chart_ver
    values_file  = "./values.yaml"
    # Removed empty secret_generator to prevent validation errors
    secret_generator = []
  }]
  resources = [
    "namespace.yaml"
  ]
}

resource "local_file" "kustomization" {
  filename = "${var.path}/kustomization.yaml"
  content  = module.kustomization.manifest
}

module "namespace" {
  source = "../../objects/namespace"

  name = var.namespace
}

resource "local_file" "namespace" {
  filename = "${var.path}/namespace.yaml"
  content  = module.namespace.manifest
}

module "serviceaccount" {
  source = "../../objects/serviceaccount"

  name        = var.service_account_name
  namespace   = var.namespace
  annotations = var.service_account_annotations
  labels      = var.service_account_labels
}

resource "local_file" "serviceaccount" {
  filename = "${var.path}/serviceaccount.yaml"
  content  = module.serviceaccount.manifest
}

locals {
  primary_env_vars = {
    CODER_URL = var.primary_access_url
  }
  env_vars = [
    for k, v in merge(local.primary_env_vars, var.env_vars) : { name = k, value = v }
  ]
  topology_spread_constraints = [
    for v in var.topology_spread_constraints : {
      maxSkew           = v.max_skew
      topologyKey       = v.topology_key
      whenUnsatisfiable = v.when_unsatisfiable
      labelSelector     = v.label_selector
      matchLabelKeys    = v.match_label_keys
    }
  ]
  # Shortened name for readability because full Kubernetes field name is excessively long
  pod_anti_affinity_preferred = [
    for v in var.pod_anti_affinity_preferred_during_scheduling_ignored_during_execution : {
      weight = v.weight
      podAffinityTerm = {
        labelSelector = v.pod_affinity_term.label_selector
        topologyKey   = v.pod_affinity_term.topology_key
      }
    }
  ]
}

resource "local_file" "values" {
  filename = "${var.path}/values.yaml"
  content = yamlencode({
    coder = {
      image = {
        repo        = var.image_repo
        tag         = var.image_tag
        pullPolicy  = var.image_pull_policy
        pullSecrets = var.image_pull_secrets
      }
      serviceAccount = {
        workspacePerms    = true
        enableDeployments = true
        name              = var.extern_prov_service_account_name
        disableCreate     = false
        annotations       = var.extern_prov_service_account_annotations
      }
      env = local.env_vars
      securityContext = {
        runAsNonRoot           = true
        runAsUser              = 1000
        runAsGroup             = 1000
        readOnlyRootFilesystem = null
        seccompProfile = {
          type = "RuntimeDefault"
        }
        allowPrivilegeEscalation = false
      }
      resources = {
        requests = var.resource_requests
        limits   = var.resource_limits
      }
      nodeSelector              = var.node_selector
      replicaCount              = var.replica_count
      tolerations               = var.tolerations
      topologySpreadConstraints = local.topology_spread_constraints
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = local.pod_anti_affinity_preferred
        }
      }
    }
  })
}