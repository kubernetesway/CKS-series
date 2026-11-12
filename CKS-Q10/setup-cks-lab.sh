#!/bin/bash

# =====================================================
# CKS LAB AUTOMATED SETUP
# Namespace: cks-limited
# User: cks-trainee
# =====================================================

set -euo pipefail

NAMESPACE="cks-limited"
TRAINEE="cks-trainee"
SA_NAME="secret-reader"
LAB_DIR="$(pwd)"

echo "======================================"
echo " Starting CKS Lab Setup"
echo "======================================"

# 1. Check prerequisites
for cmd in kubectl openssl base64; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: $cmd is not installed"
        exit 1
    }
done

# 2. Capture current admin context and cluster
ADMIN_CONTEXT=$(kubectl config current-context)

CLUSTER=$(kubectl config view --minify  -o jsonpath='{.contexts[0].context.cluster}')

echo "Admin context: $ADMIN_CONTEXT"
echo "Cluster: $CLUSTER"

if [[ "$ADMIN_CONTEXT" == "$TRAINEE" ]]; then
    echo "ERROR: Please switch to your admin context first."
    exit 1
fi

# 3. Create namespace
echo "[1/10] Creating namespace..."

kubectl create namespace "$NAMESPACE"  --dry-run=client -o yaml | kubectl apply -f -

# 4. Create three secrets
echo "[2/10] Creating three secrets..."

kubectl create secret generic secret-one     --from-literal=username=admin-one     --from-literal=password='Absdjdh##@111'     -n "$NAMESPACE"     --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic secret-two     --from-literal=username=admin-two     --from-literal=password='qheiRGa@222'  -n "$NAMESPACE"     --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic secret-three     --from-literal=username=admin-three     --from-literal=password='asbndpor@333'     -n "$NAMESPACE"     --dry-run=client -o yaml | kubectl apply -f -

# 5. Create ServiceAccount and apply RBAC
echo "[3/10] Creating ServiceAccount..."

kubectl create serviceaccount "$SA_NAME"     -n "$NAMESPACE"     --dry-run=client -o yaml | kubectl apply -f -

echo "[4/10] Applying ServiceAccount RBAC..."

kubectl apply -f sa-secret-role.yaml

# 6. Deploy three pods
echo "[5/10] Deploying three pods..."

kubectl apply -f three-pods.yaml

echo "Waiting for pods to become Ready..."

kubectl wait --for=condition=Ready pod     --all -n "$NAMESPACE" --timeout=180s

kubectl get pods -n "$NAMESPACE"

# 7. Apply restricted trainee RBAC
echo "[6/10] Applying trainee RBAC..."

kubectl apply -f trainee-role.yaml

# 8. Generate trainee private key and CSR
echo "[7/10] Generating trainee certificate..."

openssl genrsa -out "$LAB_DIR/cks-trainee.key" 2048

openssl req -new     -key "$LAB_DIR/cks-trainee.key"     -out "$LAB_DIR/cks-trainee.csr"     -subj "/CN=$TRAINEE"

# Dynamically encode CSR
CSR_BASE64=$(base64 < "$LAB_DIR/cks-trainee.csr" | tr -d '\n')

# Generate CSR YAML automatically
cat > "$LAB_DIR/cks-trainee-csr.yaml" <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $TRAINEE
spec:
  request: $CSR_BASE64
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - digital signature
  - key encipherment
  - client auth
EOF

# 9. Submit and approve CSR
echo "[8/10] Submitting and approving CSR..."

kubectl delete csr "$TRAINEE" --ignore-not-found

kubectl apply -f "$LAB_DIR/cks-trainee-csr.yaml"

kubectl certificate approve "$TRAINEE"

# Retrieve signed certificate
echo "Waiting for signed certificate..."

for i in $(seq 1 30); do

    CERT=$(kubectl get csr "$TRAINEE" \
        -o jsonpath='{.status.certificate}')

    if [[ -n "$CERT" ]]; then
        echo "$CERT" | base64 -d > "$LAB_DIR/cks-trainee.crt"
        break
    fi

    sleep 2
done

if [[ ! -s "$LAB_DIR/cks-trainee.crt" ]]; then
    echo "ERROR: Signed certificate was not received."
    exit 1
fi

echo "Certificate generated successfully."

# 10. Configure trainee kubeconfig
echo "[9/10] Configuring trainee kubeconfig..."

kubectl config set-credentials "$TRAINEE"     --client-certificate="$LAB_DIR/cks-trainee.crt"     --client-key="$LAB_DIR/cks-trainee.key"

kubectl config set-context "$TRAINEE"     --cluster="$CLUSTER"     --user="$TRAINEE"     --namespace="$NAMESPACE"

# Test actual trainee permissions before switching
echo "[10/10] Verifying trainee permissions..."

check_permission() {
    local resource="$1"
    local verb="$2"
    local expected="$3"

    local actual
    actual=$(kubectl --context="$TRAINEE" auth can-i \
        "$verb" "$resource" -n "$NAMESPACE")

    echo "$resource ($verb): $actual"

    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: Expected $expected but received $actual"
        exit 1
    fi
}

check_permission pods list yes
check_permission pods/exec create yes
check_permission secrets get no

# Switch to trainee context
kubectl config use-context "$TRAINEE"

echo ""
echo "======================================"
echo " CKS LAB SETUP COMPLETED SUCCESSFULLY"
echo "======================================"

echo "Current context:"
kubectl config current-context

echo ""
echo "Available pods:"
kubectl get pods

echo ""
echo "Direct secret access test:"
kubectl get secrets || true

echo ""
echo "You are now logged in as: $TRAINEE"
echo "Namespace: $NAMESPACE"

echo ""
echo "Try the following:"
echo "kubectl exec -it pod-one -- sh"
echo "kubectl exec -it pod-two -- sh"
echo "kubectl exec -it pod-three -- sh"

echo ""
echo "To return to admin:"
echo "kubectl config use-context $ADMIN_CONTEXT"