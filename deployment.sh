#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### Clustern name: name of your k8s cluster
### dttoken: Dynatrace api token with ingest metrics and otlp ingest scope
### dturl : url of your DT tenant wihtout any / at the end for example: https://dedede.live.dynatrace.com
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
echo "parsing arguments"
while [ $# -gt 0 ]; do
  case "$1" in
    --dtoperatortoken)
       DTOPERATORTOKEN="$2"
      shift 2
       ;;
    --dtingesttoken)
       DTTOKEN="$2"
      shift 2
       ;;
    --dturl)
       DTURL="$2"
      shift 2
       ;;
    --clustername)
      CLUSTERNAME="$2"
      shift 2
      ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done
echo "Checking arguments"
if [ -z "$CLUSTERNAME" ]; then
  echo "Error: clustername not set!"
  exit 1
fi
if [ -z "$DTURL" ]; then
  echo "Error: Dt url not set!"
  exit 1
fi

if [ -z "$DTTOKEN" ]; then
  echo "Error: Data ingest api-token not set!"
  exit 1
fi

if [ -z "$DTOPERATORTOKEN" ]; then
  echo "Error: DT operator token not set!"
  exit 1
fi



#### Deploy the cert-manager
echo "Deploying Cert Manager ( for OpenTelemetry Operator)"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m
# Deploy the opentelemetry operator
sleep 10
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}');
# Add Kepler
echo "Deploying Kepler"
helm repo add kepler https://sustainable-computing-io.github.io/kepler-helm-chart
helm install kepler kepler/kepler --namespace kepler --set canMount.usrSrc=false --create-namespace


echo "************************************************************************"
echo "***      DEPLOYMENT MODDE SELECTED : Collector                      ***"
echo "************************************************************************"
istioctl install -f istio/istio-operator.yaml --skip-confirmation



### get the ip adress of ingress ####
IP=""
while [ -z $IP ]; do
  echo "Waiting for external IP"
  IP=$(kubectl get svc istio-ingressgateway -n istio-system -ojson | jq -j '.status.loadBalancer.ingress[].ip')
  [ -z "$IP" ] && sleep 10
done
echo 'Found external IP: '$IP

### Update the ip of the ip adress for the ingres
#TODO to update this part to create the various Gateway rules
sed -i "s,IP_TO_REPLACE,$IP," istio/istio_gateway.yaml
sed -i "s,IP_TO_REPLACE,$IP," hipstershop/k8s-manifest.yaml
sed -i "s,IP_TO_REPLACE,$IP," opentelemetry/deployment.yaml
sed -i "s,IP_TO_REPLACE,$IP," hipstershop/k8s-manifest.yaml

helm install prometheus prometheus-community/kube-prometheus-stack

kubectl create ns fluentbit
kubectl apply -f fluentbit/rbac.yaml -n fluentbit
DT_HOST=$(echo $DTURL | grep -oP 'https://\K\S+')
kubectl create secret generic dynatrace -n fluentbit  --from-literal=clustername="$CLUSTERNAME" --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=dynatrace_oltp_host="$DT_HOST" --from-literal=clusterid=$CLUSTERID  --from-literal=dt_api_token="$DTTOKEN"
kubectl apply -f fluentbit/pipeline/fluentbit.yaml -n fluentbit
kubectl apply -f  fluentbit/rbac.yaml -n fluentbit
kubectl apply -f fluentbit/fluent.yaml -n fluentbit
kubectl apply -f fluentbit/fluentbitsvc.yaml -n fluentbit
#### Deploy the Dynatrace Operator
kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v0.15.0/kubernetes.yaml
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v0.15.0/kubernetes-csi.yaml
kubectl -n dynatrace wait pod --for=condition=ready --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook --timeout=300s
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DTOPERATORTOKEN" --from-literal="dataIngestToken=$DTTOKEN"
sed -i "s,TENANTURL_TOREPLACE,$DTURL," dynatrace/dynakube.yaml
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME,"  dynatrace/dynakube.yaml
kubectl apply -f dynatrace/dynakube.yaml -n dynatrace
# Deploy collector
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=clustername="$CLUSTERNAME"  --from-literal=clusterid=$CLUSTERID  --from-literal=dt_api_token="$DTTOKEN"
kubectl apply -f opentelemetry/rbac.yaml

kubectl create ns otel-demo
kubectl label namespace otel-demo istio-injection=enabled
kubectl label namespace  otel-demo oneagent=false



kubectl create ns hipster-shop
kubectl label namespace hipster-shop istio-injection=enabled
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL"  --from-literal=dt_api_token="$DTTOKEN" -n hipster-shop


echo "Deploy Demo Application for Collector"
kubectl apply -f openTelemetry/deployment.yaml -n otel-demo
kubectl apply -f hipstershop/k8s-manifest.yaml -n hipster-shop

kubectl apply -f istio/istio_gateway.yaml

echo "--------------Demo--------------------"
echo "url of the demo: "
echo "hipstershop url: http://hipstershop.$IP.nip.io"
echo "oteldemo url: http://oteldemo.$IP.nip.io"
echo "========================================================"


