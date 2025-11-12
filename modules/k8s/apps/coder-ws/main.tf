terraform {
  required_providers {
    local = {
      source = "hashicorp/local"
    }
  }
}

variable "path" {
  type = string
}

variable "namespace" {
  type = string
}

variable "image_repo" {
  type = string
}

variable "image_tag" {
  type = string
}

variable "image_pull_policy" {
  type    = string
  default = "IfNotPresent"
}

variable "image_pull_secrets" {
  type    = list(string)
  default = []
}

variable "coder_provisioner_helm_version" {
  type    = string
  default = "2.23.0"
}

variable "coder_logstream_kube_version" {
  type    = string
  default = "0.0.11"
}

variable "primary_access_url" {
  type = string
}

variable "service_account_name" {
  type = string
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
  type    = number
  default = 0
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
    cpu    = "250m"
    memory = "512Mi"
  }
}

variable "resource_limits" {
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "500m"
    memory = "1Gi"
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

variable "provisioner_secret" {
  type = object({
    key_secret_name                  = string
    key_secret_key                   = string
    key_secret_path                  = string
    termination_grace_period_seconds = optional(number, 600)
  })
  sensitive = true
}

variable "kustomize_resources" {
  type    = list(string)
  default = []
}

variable "patches" {
  type = list(object({
    expected = list(object({
      op    = string
      path  = string
      value = optional(any)
    }))
    target = object({
      group   = optional(string, "")
      version = string
      kind    = string
      name    = string
    })
  }))
  default = []
}

locals {
  patches = [for v in var.patches : {
    patch  = v.expected
    target = v.target
  }]
}

module "kustomization" {
  source    = "../../objects/kustomization"
  namespace = var.namespace
  helm_charts = [{
    name         = "coder-provisioner"
    release_name = "coder-provisioner"
    repo         = "https://helm.coder.com/v2"
    namespace    = var.namespace
    include_crds = true
    version      = var.coder_provisioner_helm_version
    values_file  = "./values.yaml"
    }, {
    name         = "coder-logstream-kube"
    release_name = "coder-logstream-kube"
    repo         = "https://helm.coder.com/logstream-kube"
    namespace    = var.namespace
    include_crds = true
    version      = var.coder_logstream_kube_version
    values_inline = {
      url = var.primary_access_url
    }
  }]
  secret_generator = [{
    name      = var.provisioner_secret.key_secret_name
    namespace = var.namespace
    behavior  = "create"
    files = [
      join("/", [
        var.provisioner_secret.key_secret_path,
        var.provisioner_secret.key_secret_key
      ])
    ]
    options = {
      disable_name_suffix_hash = true
    }
  }]
  patches = local.patches
  resources = concat([
    "namespace.yaml",
    "serviceaccount.yaml"
  ], var.kustomize_resources)
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
    provisionerDaemon = {
      keySecretKey                  = var.provisioner_secret.key_secret_key
      keySecretName                 = var.provisioner_secret.key_secret_name
      terminationGracePeriodSeconds = var.provisioner_secret.termination_grace_period_seconds
    }
  })
}