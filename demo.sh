#!/usr/bin/env bash
# Joue chaque scénario de la vidéo 3 (Helm) sur le cluster kind « demo » et écrit les sorties dans preuves/.
# Prérequis : Docker, kind, Helm 4, le cluster (`kind create cluster --name demo --config kind-cluster.yaml`) et
# l'image (`./mvnw package` puis `docker build -t orders:3.9 .`). Durée : ~30 min.
# HELM3_BIN=<chemin d'un helm 3> ajoute la comparaison avec Helm 3 (partie helm3).
# `ETAPE=prep|chart|types|configmap|valeurs|hpa|migration|helm3|secret bash demo.sh` rejoue une seule partie (dans l'ordre : chaque
# partie part de l'état laissé par la précédente).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash sous Windows : ne pas réécrire les chemins passés au cluster
cd "$(dirname "$0")"
ETAPE=${ETAPE:-tout}
partie() { [ "$ETAPE" = tout ] || [ "$ETAPE" = "$1" ]; }

HELM_BIN=${HELM_BIN:-helm}
h() { "$HELM_BIN" --kube-context kind-demo "$@"; }
# kubectl du nœud de contrôle : même version que le cluster.
k() { docker exec -i demo-control-plane kubectl "$@"; }
# Affiche la commande telle qu'on la tape, puis sa sortie.
# Les chemins de travail sont affichés comme on les taperait : values-prod.yaml.
propre() { sed -E 's#(\.travail/[a-z0-9.-]*|chart/orders(-naif)?/)values-prod[a-z0-9.-]*\.yaml#values-prod.yaml#g; s#\.travail/##g'; }
hrun() { echo "\$ helm $*" | propre; h "$@" 2>&1 || true; echo; }
krun() { echo "\$ kubectl $*"; k "$@" 2>&1 || true; echo; }
info() { echo "\$ curl -s http://orders.$1/info"; k exec client -- curl -s -m 5 "http://orders.$1/info" || echo "(pas de réponse)"; echo; echo; }
# Pods de l'appli qui ne sont pas en cours d'arrêt, du plus ancien au plus récent : nom, image, prêt, redémarrages,
# raison d'attente éventuelle.
pods() {
  echo "\$ kubectl get pods -n $1 -l app.kubernetes.io/name=orders"
  { echo "|NOM|IMAGE|PRÊT|REDÉMARRAGES|ATTENTE"
    k get pods -n "$1" -l app.kubernetes.io/name=orders --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.metadata.name}{"|"}{.spec.containers[0].image}{"|"}{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].restartCount}{"|"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}'
  } | awk -F'|' '$1=="" {printf "%-26s %-12s %-6s %-13s %s\n", $2, $3, $4, $5, $6}'
  echo
}
# Charge de calcul pour l'autoscaling : 3 boucles sans pause sur /calcul (~50 ms de processeur par requête).
lancer_calcul() { k exec client -- sh -c "rm -f /tmp/stop; for n in 1 2 3; do nohup sh -c 'while [ ! -f /tmp/stop ]; do curl -s -o /dev/null -m 5 http://orders.$1/calcul; done' >/dev/null 2>&1 & done"; }
arreter_calcul() { k exec client -- touch /tmp/stop; }
# Attend (5 min au plus) que l'autoscaler veuille $2 copies, puis qu'elles soient toutes prêtes. Écrit les deux temps,
# comptés depuis l'appel, ou « délai dépassé ».
attendre_copies() {
  local debut voulu="" pret=""; debut=$(date +%s)
  for i in $(seq 1 150); do
    local v r; v=$(k get deployment orders -n "$1" -o jsonpath='{.spec.replicas}'); r=$(k get deployment orders -n "$1" -o jsonpath='{.status.readyReplicas}')
    [ -z "$voulu" ] && [ "${v:-0}" -ge "$2" ] && voulu=$(( $(date +%s) - debut ))
    [ -n "$voulu" ] && [ "${r:-0}" -ge "$2" ] && { pret=$(( $(date +%s) - debut )); break; }
    sleep 2
  done
  if [ -z "$pret" ]; then echo "($2 copies : délai de 5 min dépassé, voulues=${v:-?} prêtes=${r:-?})"
  else echo "($2 copies voulues au bout de $voulu s, toutes prêtes au bout de $pret s)"; fi
}
# Copies voulues et prêtes, relevées pendant la minute qui suit une commande.
suivre_copies() {
  local prec=0
  for s in 1 3 5 10 15 20 30 45 60; do
    sleep $(( s - prec )); prec=$s
    echo "à $s s : $(k get deployment orders -n "$1" -o jsonpath='voulues={.spec.replicas} prêtes={.status.readyReplicas}')"
  done
  echo
}
# Avant de retirer replicas du chart (passage à l'autoscaler) : un autre gestionnaire de champs prend replicas à sa
# valeur actuelle, pour que Kubernetes ne le remette pas à 1 quand Helm l'abandonne (doc Kubernetes, Server-Side Apply,
# « Transferring ownership »).
passage_hpa() {
  local n; n=$(k get deployment orders -n "$1" -o jsonpath='{.spec.replicas}')
  printf 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
spec:
  replicas: %s
' "$n"     | k apply --server-side --field-manager=handover-to-hpa --validate=false -n "$1" -f -
}
chrono() { date +%s.%N; }
duree() { awk -v a="$1" -v b="$(chrono)" 'BEGIN{printf "%.1f s", b-a}'; }
# Les valeurs de production avant la sortie de la 3.10 : la même ligne, avec la version précédente.
mkdir -p .travail
prod_39() { sed 's/^  tag: .*/  tag: "3.9"/' chart/orders-naif/values-prod.yaml > .travail/values-prod-3.9.yaml; }

if partie prep; then
  echo "== Préparation"
  docker tag orders:3.9 orders:3.10
  docker rmi orders:3.1 >/dev/null 2>&1 || true
  # Aucune image 3.1 dans le cluster (ni sur Docker Hub) : c'est celle que demandera le chart à cause du piège des types.
  # Toutes les étiquettes désignent la même image : on la retire entièrement du nœud, puis on recharge 3.9 et 3.10.
  docker exec demo-control-plane crictl rmi docker.io/library/orders:3.1 >/dev/null 2>&1 || true
  kind load docker-image orders:3.9 orders:3.10 --name demo >/dev/null
  for ns in dev prod; do
    h uninstall orders -n "$ns" --wait >/dev/null 2>&1 || true
    k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
    k delete events --all -n "$ns" >/dev/null
    # Le Secret de la base est créé hors de Helm, une fois par environnement.
    k create secret generic postgres-db -n "$ns" --from-literal=password=Sup3r-Secret --dry-run=client -o yaml \
      | k apply -f - >/dev/null
  done
  for ns in dev prod; do k apply -n "$ns" -f - < k8s/postgres.yaml >/dev/null; done
  for ns in dev prod; do k rollout status deployment/postgres -n "$ns" --timeout=300s >/dev/null; done
  if [ "$(k get pod client -o jsonpath='{.status.phase}' 2>/dev/null)" != Running ]; then
    k delete pod client --ignore-not-found --now >/dev/null
    k run client --image=curlimages/curl:8.17.0 --restart=Never --command -- sleep infinity >/dev/null
    k wait --for=condition=Ready pod/client --timeout=200s >/dev/null
  fi
  k apply -f - < k8s/metrics-server.yaml >/dev/null
  { krun version; hrun version; krun get nodes; } > preuves/00-cluster.txt
fi

if partie chart; then
  echo "== 1. Le chart"
  rm -rf .travail/helm-create && mkdir -p .travail/helm-create
  {
    echo "# Ce que génère helm create :"
    echo "\$ helm create mon-appli"
    (cd .travail/helm-create && "$HELM_BIN" create mon-appli >/dev/null && find mon-appli -type f | sort && \
      echo && echo "$(find mon-appli -type f | wc -l) fichiers, $(cat $(find mon-appli -type f) | wc -l) lignes")
    echo
    echo "# Notre chart :"
    (cd chart && find orders -type f | sort && echo && echo "$(find orders -type f | wc -l) fichiers, $(cat $(find orders -type f) | wc -l) lignes")
  } > preuves/01-chart.txt
  prod_39
  {
    hrun lint chart/orders-naif -f .travail/values-prod-3.9.yaml
    echo "# Le YAML que Helm enverrait au cluster, sans rien installer (extrait) :"
    echo "\$ helm template orders chart/orders-naif -f values-prod.yaml | grep -E 'kind:|replicas:|image:'"
    h template orders chart/orders-naif -f .travail/values-prod-3.9.yaml | grep -E 'kind:|replicas:|image:'
    echo
  } > preuves/02-template.txt
  # Ce que YAML fait des valeurs qui ressemblent à des nombres : un chart d'essai d'un seul modèle.
  mkdir -p .travail/types/templates
  printf 'apiVersion: v2
name: types
version: 1.0.0
' > .travail/types/Chart.yaml
  printf 'tag: 3.10
codePostal: 01000
identifiant: 0042
version: "3.10"
' > .travail/types/values.yaml
  printf 'tag: {{ .Values.tag }}
codePostal: {{ .Values.codePostal }}
identifiant: {{ .Values.identifiant }}
version: {{ .Values.version }}
' > .travail/types/templates/valeurs.yaml
  {
    echo "\$ cat values.yaml"; cat .travail/types/values.yaml; echo
    echo "\$ cat templates/valeurs.yaml"; cat .travail/types/templates/valeurs.yaml; echo
    echo "\$ helm template essai ."; h template essai .travail/types | grep -v '^#\|^---'; echo
    echo "# Le chart corrigé déclare image.tag comme texte (values.schema.json) :"
    hrun lint chart/orders -f chart/orders-naif/values-prod.yaml
  } > preuves/15-types-yaml.txt 2>&1
  {
    t=$(chrono)
    hrun install orders chart/orders-naif -n dev
    hrun install orders chart/orders-naif -n prod -f .travail/values-prod-3.9.yaml --wait
    echo "# install prod avec --wait : $(duree "$t") au total"; echo
    k rollout status deployment/orders -n dev --timeout=300s >/dev/null
    hrun list -A
    pods dev; pods prod
    info dev; info prod
  } > preuves/03-install.txt 2>&1
fi

if partie types; then
  echo "== 2. 3.10 devient 3.1"
  {
    echo "# values-prod.yaml : la nouvelle version, écrite sans guillemets"
    echo "\$ grep tag values-prod.yaml"; grep tag chart/orders-naif/values-prod.yaml; echo
    hrun lint chart/orders-naif -f chart/orders-naif/values-prod.yaml
    echo "\$ helm template orders chart/orders-naif -f values-prod.yaml | grep image:"
    h template orders chart/orders-naif -f chart/orders-naif/values-prod.yaml | grep 'image:'; echo
    t=$(chrono)
    hrun upgrade orders chart/orders-naif -n prod -f chart/orders-naif/values-prod.yaml
    echo "# helm upgrade rendu en $(duree "$t")"; echo
    hrun list -n prod
    echo "# 90 secondes plus tard :"; sleep 90
    pods prod
    echo "\$ kubectl get events -n prod --field-selector reason=Failed | grep -o 'Failed to pull image[^:]*:[^ ]*' | sort -u"
    k get events -n prod --field-selector reason=Failed -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' \
      | grep -o 'Failed to pull image "[^"]*"' | sort -u || true; echo
    info prod
  } > preuves/04-version-3-1.txt 2>&1
  {
    hrun rollback orders 1 -n prod --wait
    pods prod
    echo "# La même erreur, cette fois avec --rollback-on-failure (attente comprise) et 2 minutes au plus :"
    t=$(chrono)
    hrun upgrade orders chart/orders-naif -n prod -f chart/orders-naif/values-prod.yaml --rollback-on-failure --timeout 2m
    echo "# Échec signalé et retour arrière fait en $(duree "$t")"; echo
    pods prod
    hrun history orders -n prod
  } > preuves/05-rollback-on-failure.txt 2>&1
  {
    sed 's/^  tag: 3.10/  tag: "3.10"/' chart/orders-naif/values-prod.yaml > .travail/values-prod-ok.yaml
    echo "# La même ligne, entre guillemets :"
    echo "\$ grep tag values-prod.yaml"; grep tag .travail/values-prod-ok.yaml; echo
    t=$(chrono)
    hrun upgrade orders chart/orders-naif -n prod -f .travail/values-prod-ok.yaml --rollback-on-failure --timeout 5m
    echo "# Mise à jour attendue jusqu'au bout : $(duree "$t")"; echo
    pods prod
    info prod
  } > preuves/06-guillemets.txt 2>&1
fi

if partie configmap; then
  echo "== 3. Le ConfigMap qui ne sert à rien"
  {
    pods dev
    hrun upgrade orders chart/orders-naif -n dev --set message=Salut --wait
    echo "\$ kubectl get configmap orders-config -n dev -o jsonpath='{.data.APP_MESSAGE}'"
    k get configmap orders-config -n dev -o jsonpath='{.data.APP_MESSAGE}'; echo; echo
    echo "# 60 secondes plus tard :"; sleep 60
    pods dev
    info dev
  } > preuves/07-configmap-sans-checksum.txt 2>&1
  {
    echo "# Le chart corrigé (checksum/config), installé une première fois avec le message d'origine :"
    hrun upgrade orders chart/orders -n dev --set message=Bonjour --wait
    pods dev
    hrun upgrade orders chart/orders -n dev --set message=Salut --wait
    pods dev
    info dev
    echo "\$ kubectl get deployment orders -n dev -o jsonpath='{.spec.template.metadata.annotations}'"
    k get deployment orders -n dev -o jsonpath='{.spec.template.metadata.annotations}'; echo
  } > preuves/08-configmap-avec-checksum.txt 2>&1
fi

if partie valeurs; then
  echo "== 4. Un seul --set, et la prod repart avec les valeurs de dev"
  cp chart/orders/values-prod.yaml .travail/values-prod-final.yaml
  passage_hpa prod >/dev/null
  h upgrade orders chart/orders -n prod -f .travail/values-prod-final.yaml --rollback-on-failure --timeout 5m >/dev/null
  {
    echo "# La prod, sur le chart corrigé, avec values-prod.yaml :"
    hrun get values orders -n prod
    krun get deployment,hpa -n prod -l app.kubernetes.io/name=orders
    info prod
    echo "# On change seulement le message, sans redonner values-prod.yaml :"
    hrun upgrade orders chart/orders -n prod --set message=Promo --wait
    hrun get values orders -n prod
    sleep 5
    krun get deployment,hpa -n prod -l app.kubernetes.io/name=orders
    info prod
  } > preuves/09-set-seul.txt 2>&1
  {
    echo "# Sans aucune valeur, Helm reprend celles de la version précédente :"
    h upgrade orders chart/orders -n prod -f .travail/values-prod-final.yaml --wait >/dev/null
    hrun upgrade orders chart/orders -n prod --wait
    hrun get values orders -n prod
    echo "# La bonne commande : le fichier de l'environnement à chaque fois, et la surcharge en plus."
    hrun upgrade orders chart/orders -n prod -f .travail/values-prod-final.yaml --set message=Promo --wait
    hrun get values orders -n prod
    sleep 5
    krun get deployment,hpa -n prod -l app.kubernetes.io/name=orders
    info prod
  } > preuves/10-valeurs-reprises.txt 2>&1
fi

if partie hpa; then
  echo "== 5. replicas dans le chart et autoscaler"
  # Mémoire : jusqu'à 6 JVM en prod pendant ces scénarios. Le dev n'est plus utilisé que pour son historique Helm
  # (partie secret), on arrête son pod.
  k scale deployment orders -n dev --replicas=0 >/dev/null 2>&1 || true
  # Dans l'espace prod (la base y est déjà), à la place de la release des scénarios précédents.
  h uninstall orders -n prod --wait >/dev/null 2>&1 || true
  prod_39
  cp chart/orders/values-prod.yaml .travail/values-prod-final.yaml
  sed -i 's/^  tag: .*/  tag: "3.9"/' .travail/values-prod-final.yaml
  {
    echo "# Le chart naïf : replicas: 3 dans le Deployment, ET un autoscaler (3 à 6 copies)."
    hrun install orders chart/orders-naif -n prod -f .travail/values-prod-3.9.yaml --wait
    echo "# Du trafic de calcul : l'autoscaler ajoute des copies."
    lancer_calcul prod
    attendre_copies prod 6; echo
    krun get deployment,hpa -n prod -l app.kubernetes.io/name=orders
    echo "# Qui a écrit quoi dans le Deployment (managedFields) :"
    echo "\$ kubectl get deployment orders -n prod -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.subresource}{\"\n\"}{end}'"
    k get deployment orders -n prod -o jsonpath='{range .metadata.managedFields[*]}{.manager}{" "}{.operation}{" "}{.subresource}{"\n"}{end}'; echo
    echo "# Une mise à jour qui ne touche qu'au message :"
    hrun upgrade orders chart/orders-naif -n prod -f .travail/values-prod-3.9.yaml --set message=Promo
    hrun history orders -n prod
    echo "# Le réflexe : forcer."
    hrun upgrade orders chart/orders-naif -n prod -f .travail/values-prod-3.9.yaml --set message=Promo --force-conflicts
    suivre_copies prod
  } > preuves/11-replicas-et-hpa.txt 2>&1
  arreter_calcul prod
  h uninstall orders -n prod --wait >/dev/null
  sleep 10
  {
    echo "# Le chart corrigé : pas de replicas quand l'autoscaling est activé."
    hrun install orders chart/orders -n prod -f .travail/values-prod-final.yaml --wait
    lancer_calcul prod
    attendre_copies prod 6; echo
    krun get deployment,hpa -n prod -l app.kubernetes.io/name=orders
    hrun upgrade orders chart/orders -n prod -f .travail/values-prod-final.yaml --set message=Promo
    suivre_copies prod
  } > preuves/12-hpa-corrige.txt 2>&1
  arreter_calcul prod
fi

if partie migration; then
  echo "== 5 ter. Passer une release existante au chart corrigé"
  prod_39
  cp chart/orders/values-prod.yaml .travail/values-prod-final.yaml
  sed -i 's/^  tag: .*/  tag: "3.9"/' .travail/values-prod-final.yaml
  champs() {
    echo "\$ kubectl get deployment orders -n prod -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.subresource}{\"\n\"}{end}'"
    k get deployment orders -n prod -o jsonpath='{range .metadata.managedFields[*]}{.manager}{" "}{.operation}{" "}{.subresource}{"\n"}{end}'; echo
  }
  {
    h uninstall orders -n prod --wait >/dev/null 2>&1 || true
    echo "# La prod tourne sur le premier chart (replicas: 3, autoscaler 3 à 6), sans charge."
    hrun install orders chart/orders-naif -n prod -f .travail/values-prod-3.9.yaml --wait
    sleep 20
    champs
    echo "# On passe au chart corrigé, qui ne contient plus replicas :"
    hrun upgrade orders chart/orders -n prod -f .travail/values-prod-final.yaml
    suivre_copies prod
  } > preuves/12b-migration.txt 2>&1
  {
    h uninstall orders -n prod --wait >/dev/null 2>&1 || true
    echo "# Même départ. Cette fois, un autre gestionnaire prend d'abord replicas à sa valeur actuelle :"
    h install orders chart/orders-naif -n prod -f .travail/values-prod-3.9.yaml --wait >/dev/null
    sleep 20
    echo "\$ kubectl apply --server-side --field-manager=handover-to-hpa --validate=false -f replicas-seulement.yaml"
    echo "# replicas-seulement.yaml :"
    printf 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
spec:
  replicas: 3
'
    passage_hpa prod; echo
    champs
    hrun upgrade orders chart/orders -n prod -f .travail/values-prod-final.yaml
    suivre_copies prod
  } > preuves/12c-migration-passage.txt 2>&1
fi

if partie helm3 && [ -n "${HELM3_BIN:-}" ]; then
  echo "== 5 bis. Le même piège avec Helm 3 (pour comparer)"
  arreter_calcul prod
  h uninstall orders -n prod --wait >/dev/null 2>&1 || true
  sleep 10
  prod_39
  h3() { "$HELM3_BIN" --kube-context kind-demo "$@"; }
  {
    echo "\$ helm3 version"; h3 version; echo
    echo "\$ helm3 install orders chart/orders-naif -n prod -f values-prod.yaml --wait"
    h3 install orders chart/orders-naif -n prod -f .travail/values-prod-3.9.yaml --wait 2>&1 | grep -E 'STATUS|REVISION'; echo
    lancer_calcul prod
    attendre_copies prod 6; echo
    krun get deployment,hpa -n prod -l app.kubernetes.io/name=orders
    echo "\$ helm3 upgrade orders chart/orders-naif -n prod -f values-prod.yaml --set message=Promo"
    h3 upgrade orders chart/orders-naif -n prod -f .travail/values-prod-3.9.yaml --set message=Promo 2>&1 | grep -E 'STATUS|REVISION|Error'; echo
    suivre_copies prod
  } > preuves/11b-helm3-replicas.txt 2>&1
  arreter_calcul prod
  h3 uninstall orders -n prod --wait >/dev/null 2>&1 || true
fi

if partie secret; then
  echo "== 6. Le mot de passe dans l'historique"
  {
    echo "# Le chart naïf a mis le mot de passe dans values.yaml. Helm garde chaque version dans le cluster :"
    krun get secrets -n dev -l owner=helm
    echo "# Toutes les valeurs de la version 1, défauts du chart compris :"
    echo "\$ helm get values orders -n dev --revision 1 --all | grep -A3 '^database'"
    h get values orders -n dev --revision 1 --all | grep -A3 '^database' || echo "(révision 1 introuvable)"; echo
    echo "# Sans Helm, avec les seuls droits de lecture sur les Secrets de l'espace de noms :"
    echo "\$ kubectl get secret sh.helm.release.v1.orders.v1 -n dev -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip | grep -o '\"password\":\"[^\"]*\"' | sort -u"
    k get secret sh.helm.release.v1.orders.v1 -n dev -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip \
      | grep -o '"password":"[^"]*"' | sort -u || echo "(révision 1 introuvable)"; echo
    echo "# Après le passage au chart corrigé (existingSecret), la dernière version ne contient plus que le nom du Secret :"
    last=$(k get secrets -n dev -l owner=helm,name=orders -o jsonpath='{range .items[*]}{.metadata.labels.version}{"\n"}{end}' | sort -n | tail -1)
    echo "\$ helm get values orders -n dev --all | grep -A3 '^database'"
    h get values orders -n dev --all | grep -A3 '^database' || true; echo
    echo "\$ … sh.helm.release.v1.orders.v$last … | grep -c Sup3r-Secret"
    k get secret "sh.helm.release.v1.orders.v$last" -n dev -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip \
      | grep -c 'Sup3r-Secret' || true; echo
    echo "# Mais la version 1 est toujours là (10 versions gardées par défaut) :"
    echo "\$ … sh.helm.release.v1.orders.v1 … | grep -c Sup3r-Secret"
    k get secret sh.helm.release.v1.orders.v1 -n dev -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip \
      | grep -c 'Sup3r-Secret' || true; echo
    hrun history orders -n dev
  } > preuves/13-mot-de-passe.txt 2>&1
  {
    echo "# L'ancien nom de --rollback-on-failure, sous Helm 4 :"
    hrun upgrade orders chart/orders -n dev --atomic --wait
  } > preuves/14-atomic.txt 2>&1
fi

echo "== Fini"
