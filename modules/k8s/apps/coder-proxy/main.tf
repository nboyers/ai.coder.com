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

variable "coder_helm_version" {
  type = string
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.coder_helm_version))
    error_message = "Helm version must be in semver format (e.g., 2.23.0)"
  }
}

variable "image_repo" {
  type    = string
  default = "ghcr.io/coder/coder"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "image_pull_policy" {
  type    = string
  default = "IfNotPresent"
}

variable "image_pull_secrets" {
  type    = list(string)
  default = []
}

variable "replica_count" {
  type    = number
  default = 0
}

variable "env_vars" {
  type    = map(string)
  default = {}
}

variable "load_balancer_class" {
  type    = string
  default = "service.k8s.aws/nlb"
}

variable "resource_request" {
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "250m"
    memory = "512Mi"
  }
}

variable "resource_limit" {
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "500m"
    memory = "1Gi"
  }
}

variable "service_annotations" {
  type    = map(string)
  default = {}
}

variable "service_account_annotations" {
  type    = map(string)
  default = {}
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

variable "primary_access_url" {
  type = string
  validation {
    condition     = can(regex("^https?://", var.primary_access_url))
    error_message = "Primary access URL must start with http:// or https://"
  }
}

variable "proxy_access_url" {
  type = string
  validation {
    condition     = can(regex("^https?://", var.proxy_access_url))
    error_message = "Proxy access URL must start with http:// or https://"
  }
}

variable "proxy_wildcard_url" {
  type = string
  validation {
    condition     = can(regex("^https?://", var.proxy_wildcard_url))
    error_message = "Proxy wildcard URL must start with http:// or https://"
  }
}

variable "termination_grace_period_seconds" {
  type    = number
  default = 600
}

variable "cert_config" {
  type = object({
    name          = string
    create_secret = optional(bool, true)
    key_path      = string
    crt_path      = string
  })
}

variable "proxy_token_config" {
  type = object({
    name = string
    path = string
  })
}

variable "patches" {
  type = list(object({
    target = object({
      group   = optional(string, "")
      version = string
      kind    = string
      name    = string
    })
    expected = list(object({
      op    = string
      path  = string
      value = optional(any)
    }))
  }))
  default = []
}

locals {
  values_file    = "values.yaml"
  namespace_file = "namespace.yaml"
  patches = [for v in var.patches : {
    patch  = v.expected
    target = v.target
  }]
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
    version      = var.coder_helm_version
    values_file  = "./${local.values_file}"
  }]
  secret_generator = concat([{
    name      = var.proxy_token_config.name
    namespace = var.namespace
    behavior  = "create"
    files = [
      var.proxy_token_config.path
    ]
    options = {
      disable_name_suffix_hash = true
    }
    }], var.cert_config.create_secret ? [{
    name      = var.cert_config.name,
    namespace = var.namespace
    behavior  = "create"
    files = [
      var.cert_config.crt_path,
      var.cert_config.key_path,
    ]
    options = {
      disable_name_suffix_hash = true
    }
  }] : [])
  patches = local.patches
  resources = [
    local.namespace_file
  ]
}

module "namespace" {
  source = "../../objects/namespace"

  name = var.namespace
}

resource "local_file" "namespace" {
  filename = join("/", [var.path, local.namespace_file])
  content  = module.namespace.manifest
}

resource "local_file" "kustomization" {
  filename = "${var.path}/kustomization.yaml"
  content  = module.kustomization.manifest
}

locals {
  primary_env_vars = {
    CODER_PRIMARY_ACCESS_URL  = var.primary_access_url
    CODER_ACCESS_URL          = var.proxy_access_url
    CODER_WILDCARD_ACCESS_URL = var.proxy_wildcard_url
  }
  env_vars = concat([
    for k, v in merge(local.primary_env_vars, var.env_vars) : { name = k, value = v }
    ], [{
      name = "CODER_PROXY_SESSION_TOKEN"
      valueFrom = {
        secretKeyRef = {
          name = var.proxy_token_config.name
          key  = element(split("/", var.proxy_token_config.path), -1)
        }
      }
  }])
  pod_anti_affinity_preferred_during_scheduling_ignored_during_execution = [
    for k, v in var.pod_anti_affinity_preferred_during_scheduling_ignored_during_execution : {
      weight = v.weight
      podAffinityTerm = {
        labelSelector = {
          matchLabels = try(v.pod_affinity_term.label_selector.match_labels, {})
        }
        # Removed try() wrapper - topology_key is required string, not optional
        topologyKey = v.pod_affinity_term.topology_key
      }
    }
  ]
  topology_spread_constraints = [
    for k, v in var.topology_spread_constraints : {
      maxSkew           = v.max_skew
      topologyKey       = v.topology_key
      whenUnsatisfiable = v.when_unsatisfiable
      labelSelector = {
        matchLabels = try(v.label_selector.match_labels, {})
      }
      matchLabelKeys = v.match_label_keys

    }
  ]
}

resource "local_file" "values" {
  filename = join("/", [var.path, local.values_file])
  content = yamlencode({
    coder = {
      image = {
        repo        = var.image_repo
        tag         = var.image_tag
        pullPolicy  = var.image_pull_policy
        pullSecrets = var.image_pull_secrets
      }
      workspaceProxy = true
      env            = local.env_vars
      tls = {
        secretNames = [var.cert_config.name]
      }
      service = {
        enable                = true
        type                  = "LoadBalancer"
        sessionAffinity       = "None"
        externalTrafficPolicy = "Cluster"
        loadBalancerClass     = var.load_balancer_class
        annotations           = var.service_annotations
      }
      replicaCount = var.replica_count
      resources = {
        requests = var.resource_request
        limits   = var.resource_limit
      }
      serviceAccount = {
        annotations = var.service_account_annotations
      }
      nodeSelector              = var.node_selector
      tolerations               = var.tolerations
      topologySpreadConstraints = local.topology_spread_constraints
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = local.pod_anti_affinity_preferred_during_scheduling_ignored_during_execution
        }
      }
      terminationGracePeriodSeconds = var.termination_grace_period_seconds
    }
  })

  lifecycle {
    # Recreate file on content changes to ensure consistency
    create_before_destroy = true
  }
}