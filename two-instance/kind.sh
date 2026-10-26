#!/bin/sh
# Two kind clusters for the two-instance add-on, next to the single-Project
# cluster from ../kind.sh (kargo-quickstart). Each runs its own Argo CD,
# Argo Rollouts, cert-manager and Kargo v1.12.4:
#
#   kargo-2i-dev      dev Kargo:     dev + dev-handoff
#   kargo-2i-release  release Kargo: staging + prod (both environments)
#
# Inside every cluster the NodePorts are the same as in ../kind.sh; only the
# host ports differ, so all three clusters can run at once:
#
#   cluster           Argo CD  Kargo  webhooks  apps
#   kargo-quickstart  31080    31081  31082     32080 dev, 32081 staging, 32082 prod
#   kargo-2i-dev      31180    31181  31182     32180 dev
#   kargo-2i-release  31280    31281  31282     32281 staging, 32282 prod
#
# Usage: ./kind.sh [dev|release|all]   (default: all)
# Local-only passwords: Argo CD admin/admin, Kargo admin/admin.

set -eu

argo_cd_chart_version=9.4.3
argo_rollouts_chart_version=2.40.6
cert_manager_chart_version=1.19.3
kargo_chart_version=1.12.4

# create_cluster <name> <host-port prefix: 311 or 312> <extra app port mappings>
create_cluster() {
  name=$1
  p=$2
  apps=$3
  set -x
  kind create cluster --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${name}
nodes:
- extraPortMappings:
  - containerPort: 31080 # Argo CD dashboard
    hostPort: ${p}80
  - containerPort: 31081 # Kargo dashboard
    hostPort: ${p}81
  - containerPort: 31082 # External webhooks server
    hostPort: ${p}82
${apps}
EOF
  { set +x; } 2>/dev/null
}

install_platform() {
  ctx=kind-$1
  set -x
  helm install cert-manager cert-manager \
    --kube-context "$ctx" \
    --repo https://charts.jetstack.io \
    --version $cert_manager_chart_version \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait

  helm install argocd argo-cd \
    --kube-context "$ctx" \
    --repo https://argoproj.github.io/argo-helm \
    --version $argo_cd_chart_version \
    --namespace argocd \
    --create-namespace \
    --set 'configs.secret.argocdServerAdminPassword=$2a$10$5vm8wXaSdbuff0m9l21JdevzXBzJFPCi8sy6OOnpZMAG.fOXL7jvO' \
    --set dex.enabled=false \
    --set notifications.enabled=false \
    --set server.service.type=NodePort \
    --set server.service.nodePortHttp=31080 \
    --set 'server.extraArgs={--insecure}' \
    --set server.extensions.enabled=true \
    --set 'server.extensions.extensionList[0].name=argo-rollouts' \
    --set 'server.extensions.extensionList[0].env[0].name=EXTENSION_URL' \
    --set 'server.extensions.extensionList[0].env[0].value=https://github.com/argoproj-labs/rollout-extension/releases/download/v0.3.7/extension.tar' \
    --wait

  helm install argo-rollouts argo-rollouts \
    --kube-context "$ctx" \
    --repo https://argoproj.github.io/argo-helm \
    --version $argo_rollouts_chart_version \
    --create-namespace \
    --namespace argo-rollouts \
    --wait

  # Kargo admin password is 'admin'
  helm install kargo \
    oci://ghcr.io/akuity/kargo-charts/kargo --version $kargo_chart_version \
    --kube-context "$ctx" \
    --namespace kargo \
    --create-namespace \
    --set api.service.type=NodePort \
    --set api.service.nodePort=31081 \
    --set 'server.extraArgs={--insecure}' \
    --set api.tls.enabled=false \
    --set api.adminAccount.passwordHash='$2a$10$Zrhhie4vLz5ygtVSaif6o.qN36jgs6vjtMBdM6yrU1FOeiAAMMxOm' \
    --set api.adminAccount.tokenSigningKey=iwishtowashmyirishwristwatch \
    --set database.postgres.password=kargo \
    --set externalWebhooksServer.service.type=NodePort \
    --set externalWebhooksServer.service.nodePort=31082 \
    --set externalWebhooksServer.tls.enabled=false \
    --wait
  { set +x; } 2>/dev/null
}

dev() {
  create_cluster kargo-2i-dev 311 "\
  - containerPort: 32080 # dev app (stages/dev NodePort)
    hostPort: 32180"
  install_platform kargo-2i-dev
}

release() {
  create_cluster kargo-2i-release 312 "\
  - containerPort: 32081 # staging app (stages/staging NodePort)
    hostPort: 32281
  - containerPort: 32082 # prod app (stages/prod NodePort)
    hostPort: 32282"
  install_platform kargo-2i-release
}

case "${1:-all}" in
  dev) dev ;;
  release) release ;;
  all) dev; release ;;
  *) echo "usage: $0 [dev|release|all]" >&2; exit 1 ;;
esac

echo
echo "Done. kubectl contexts: kind-kargo-2i-dev, kind-kargo-2i-release"
echo "Dev:     Argo CD http://localhost:31180  Kargo http://localhost:31181  app http://localhost:32180"
echo "Release: Argo CD http://localhost:31280  Kargo http://localhost:31281  apps http://localhost:32281 (staging) / 32282 (prod)"
