# KEDA/Kedify resources commented out - uncomment when you have proper keys
# Kedify KEDA using their Helm repo
# resource "helm_release" "keda" {
#   name             = "keda"
#   namespace        = "keda"
#   create_namespace = true
#
#   repository = "https://charts.kedify.io"
#   chart      = "keda"
#   version    = "2.18.3-0"
#
#   set {
#     name  = "env[0].name"
#     value = "KEDIFY_SCALINGGROUPS_ENABLED"
#   }
#   set {
#     name  = "env[0].value"
#     value = "true"
#   }
#
#   depends_on = [helm_release.aws_load_balancer_controller, helm_release.metrics_server]
# }
#
# # KEDA HTTP add-on (Kedify build)
# resource "helm_release" "keda_http_addon" {
#   name       = "keda-add-ons-http"
#   namespace  = "keda"
#   repository = "https://charts.kedify.io"
#   chart      = "keda-add-ons-http"
#   version    = "0.10.0-7"
#
#   depends_on = [helm_release.keda]
# }
#
# # Kedify OTEL Add-on for metric-based scaling
# resource "helm_release" "keda_otel_scaler" {
#   name       = "keda-otel-scaler"
#   namespace  = "keda"
#   repository = "oci://ghcr.io/kedify/charts"
#   chart      = "otel-add-on"
#   version    = "0.3.0"
#
#   values = [<<-EOT
#     otelOperator:
#       enabled: true
#     otelOperatorCrs:
#     - name: scrape-vllm
#       enabled: true
#       prometheusScrapeConfigs:
#       - job_name: 'vllm-metrics'
#         scrape_interval: 5s
#         kubernetes_sd_configs:
#         - role: pod
#           namespaces:
#             names:
#             - default
#         relabel_configs:
#         - source_labels: [__meta_kubernetes_pod_label_app]
#           regex: "vllm"
#           action: keep
#         - source_labels: [__meta_kubernetes_pod_name]
#           action: replace
#           target_label: pod_name
#         - source_labels: [__address__]
#           action: replace
#           target_label: __address__
#           regex: (.+):.*
#           replacement: $1:8080
#       includeMetrics:
#       - vllm_num_requests_waiting
#   EOT
#   ]
#
#   depends_on = [helm_release.keda]
# }
#
# # Kedify agent in offline mode
# resource "helm_release" "kedify_agent" {
#   name       = "kedify-agent"
#   namespace  = "keda"
#   repository = "https://charts.kedify.io"
#   chart      = "kedify-agent"
#   version    = "0.2.7"
#
#   set {
#     name  = "clusterName"
#     value = "ai-workloads-tube-demo"
#   }
#   set {
#     name  = "agent.orgId"
#     value = "00000000-0000-0000-0000-000000000000"
#   }
#   set {
#     name  = "agent.agentId"
#     value = "00000000-0000-0000-0000-000000000000"
#   }
#   set {
#     name  = "agent.apiKey"
#     value = "kfy_0000000000000000000000000000000000000000000000000000000000000000"
#   }
#   set {
#     name  = "agent.extraArgs.offline"
#     value = "true"
#   }
#
#   depends_on = [helm_release.keda]
# }
