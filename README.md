# Helm : packager son application Spring Boot pour Kubernetes (Helm 4)

Code de la 3e vidéo de la série **Kubernetes pour développeurs Java** de la chaîne
[IT Skills Maker](https://www.youtube.com/@ItSkillsMaker). Les vidéos précédentes et leur code :
[SkillMakers/kubernetes-spring-boot](https://github.com/SkillMakers/kubernetes-spring-boot) (déployer),
[SkillMakers/kubernetes-spring-boot-2](https://github.com/SkillMakers/kubernetes-spring-boot-2) (probes, mémoire, arrêt
propre, autoscaling).

La même application de commandes (Spring Boot 4.1, Java 25, PostgreSQL), ses manifestes de la vidéo 2 transformés en
chart Helm, et six pièges provoqués sur un vrai cluster Kubernetes local. Chaque sortie de la vidéo vient de
[`preuves/`](preuves/).

## Lancer

Il faut Docker, [kind](https://kind.sigs.k8s.io/), et [Helm 4](https://helm.sh/docs/intro/install/).

```
./mvnw package
docker build -t orders:3.9 .
kind create cluster --name demo --config kind-cluster.yaml
bash demo.sh
```

`demo.sh` crée deux espaces de noms (`dev` et `prod`), une base PostgreSQL dans chacun, installe le chart, joue chaque
scénario et réécrit `preuves/`. Le tout prend ~30 min ; `ETAPE=prep|chart|types|configmap|valeurs|hpa|migration|helm3|secret bash
demo.sh` rejoue une seule partie, dans l'ordre. `HELM3_BIN=<chemin d'un Helm 3>` ajoute la comparaison avec Helm 3.

Pour tout supprimer : `kind delete cluster --name demo`.

## Les deux charts

| Dossier | Ce que c'est |
|---|---|
| [`chart/orders-naif/`](chart/orders-naif/) | le chart tel qu'on l'écrit d'abord : il marche, et il contient les pièges |
| [`chart/orders/`](chart/orders/) | le chart corrigé, à reprendre |

Les différences, une par piège :

| Piège | `orders-naif` | `orders` |
|---|---|---|
| 3.10 devient 3.1 | `tag: 3.10` | `tag: "3.10"`, et `values.schema.json` qui refuse un tag qui n'est pas du texte |
| Helm n'attend pas | `helm upgrade` seul | `helm upgrade --rollback-on-failure --timeout …` (ancien nom : `--atomic`) |
| ConfigMap non relu | rien | annotation `checksum/config` dans le modèle de pod |
| Un `--set` seul | — (c'est la commande) | toujours `-f values-prod.yaml`, et la surcharge en plus |
| `replicas` et autoscaler | `replicas` toujours écrit | pas de `replicas` quand `autoscaling.enabled` |
| Mot de passe dans l'historique | `database.password` dans `values.yaml` + `templates/secret.yaml` | `database.existingSecret` (obligatoire) : le nom d'un Secret créé hors de Helm |

## Passer une release existante au chart corrigé

Le chart corrigé ne contient plus `replicas` quand l'autoscaling est activé. Sur une release qui tourne déjà avec le
premier chart, Helm 4 (server-side apply) retire alors le champ, et Kubernetes le remet à sa valeur par défaut :
**une copie**, jusqu'à ce que l'autoscaler la remonte (`preuves/12b-migration.txt`). La parade de la
[documentation Kubernetes](https://kubernetes.io/docs/reference/using-api/server-side-apply/#transferring-ownership) :
faire d'abord prendre `replicas` par un autre gestionnaire de champs, à sa valeur actuelle, puis mettre à jour
(`preuves/12c-migration-passage.txt`) :

```
kubectl apply --server-side --field-manager=handover-to-hpa --validate=false -f replicas-seulement.yaml
helm upgrade orders chart/orders -n prod -f values-prod.yaml
```

où `replicas-seulement.yaml` ne contient que `apiVersion`, `kind`, `metadata.name` et `spec.replicas`.

## Limites connues

- **Désactiver l'autoscaling après qu'il a agi** remet `replicas` dans le Deployment : Helm 4 refuse alors la mise à jour
  (le même conflit que `preuves/11`), puisque c'est l'autoscaler qui possède le champ. Passer `--force-conflicts` pour
  cette mise à jour-là, en connaissance de cause.
- **Changer le mot de passe** dans le Secret `postgres-db` ne redémarre pas les pods : comme le ConfigMap, il est lu
  dans une variable d'environnement au démarrage du conteneur. Après une rotation :
  `kubectl rollout restart deployment/orders`.

## Les preuves

Kubernetes 1.37.0 (kind v0.33.0, un nœud), Helm 4.3.2, Docker Desktop 29.3.1. Voir [`MESURES.md`](MESURES.md) pour le tableau
complet.

| Fichier | Ce qu'il montre |
|---|---|
| `00-cluster.txt` | versions de Kubernetes et de Helm |
| `01-chart.txt` | `helm create` : 12 fichiers, 539 lignes ; notre chart corrigé |
| `02-template.txt` | `helm lint` et `helm template` |
| `03-install.txt` | la même release en dev (1 copie) et en prod (3 copies) |
| `04-version-3-1.txt` | `tag: 3.10` → image `orders:3.1`, `STATUS: deployed`, pod en `ImagePullBackOff` |
| `05-rollback-on-failure.txt` | `helm rollback`, puis la même erreur avec `--rollback-on-failure` : échec et retour arrière automatique |
| `06-guillemets.txt` | `tag: "3.10"` : la 3.10 démarre |
| `07-configmap-sans-checksum.txt` | ConfigMap changé, pod inchangé, ancien message |
| `08-configmap-avec-checksum.txt` | avec `checksum/config` : pod remplacé, nouveau message |
| `09-set-seul.txt` | un `--set` seul : la prod repart en 3.9, 1 copie, sans autoscaler |
| `10-valeurs-reprises.txt` | sans valeur, Helm reprend la révision précédente ; la bonne commande |
| `11-replicas-et-hpa.txt` | Helm 4 : conflit server-side apply sur `.spec.replicas` ; `--force-conflicts` : 6 → 3 copies sous charge |
| `11b-helm3-replicas.txt` | Helm 3 : la mise à jour passe et remet 3 copies sans rien dire |
| `12-hpa-corrige.txt` | chart corrigé : aucun conflit, 6 copies voulues tout du long |
| `12b-migration.txt` | premier chart → chart corrigé sur une release qui tourne : 1 copie le temps que l'autoscaler réagisse |
| `12c-migration-passage.txt` | la même chose après `--field-manager=handover-to-hpa` : 3 copies tout du long |
| `13-mot-de-passe.txt` | le mot de passe lisible dans la révision 1, même après le passage à `existingSecret` |
| `14-atomic.txt` | `--atomic` sous Helm 4 : avertissement d'obsolescence |
| `15-types-yaml.txt` | `3.10` → `3.1`, `01000` → `512`, `0042` → `34` ; le schéma du chart corrigé refuse `tag: 3.10` |
