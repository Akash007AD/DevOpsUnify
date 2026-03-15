variable "project_name" { type = string }
variable "grafana_password" {
  type      = string
  default   = "devopsunify@123"
  sensitive = true
}

# Requires: helm provider configured with kubeconfig
resource "helm_release" "kube_prometheus_stack" {
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "57.0.1"
  namespace        = "monitoring"
  create_namespace = true

  set {
    name  = "grafana.adminPassword"
    value = var.grafana_password
  }
  set {
    name  = "grafana.service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "prometheus.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "grafana.persistence.enabled"
    value = "true"
  }
  set {
    name  = "grafana.persistence.size"
    value = "5Gi"
  }
  set {
    name  = "alertmanager.enabled"
    value = "true"
  }
}

output "monitoring_namespace" { value = "monitoring" }
