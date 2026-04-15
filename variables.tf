variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "Path to kubeconfig (same cluster Terraform and local-exec kubectl use)."
}

variable "kube_context" {
  type        = string
  default     = "rancher-desktop"
  description = "kubectl context name. Rancher Desktop typically uses rancher-desktop; set TF_VAR_kube_context for other clusters."
}

variable "keycloak_url" {
  type        = string
  default     = "http://localhost:30080"
  description = "Keycloak URL reachable from the host running Terraform (Keycloak is exposed via NodePort 30080 in this stack)."
}

locals {
  kubeconfig_expanded = pathexpand(var.kubeconfig_path)
}
