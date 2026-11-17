# Mesures — Helm : packager son application Spring Boot pour Kubernetes (17/11/2026)

Environnement : Windows 11, Docker Desktop 29.3.1 (VM WSL 2 en cgroup v1, 8 processeurs), kind v0.33.0,
**Kubernetes 1.37.0**, un seul nœud (`failCgroupV1: false`), metrics-server v0.9.1 (`--kubelet-insecure-tls`).
**Helm 4.3.2** (publié le 13/11/2026, somme SHA-256 vérifiée) ; comparaison avec **Helm 3.18.5**.
Appli : Spring Boot 4.1.2, Java 25 (Temurin), images `orders:3.9` et `orders:3.10` (même image, deux étiquettes ; la
version affichée par `/info` vient de `APP_VERSION`, posée par le chart), PostgreSQL 18. Script : `demo.sh`.

**Passage complet** sur un cluster neuf le 17/11 à 16 h (`../demo-run.log`, ~20 min), après la relecture et la revue de
code. **Ce sont ces fichiers qui font foi.** Les passages précédents avaient donné les mêmes résultats, à quelques
secondes près (la prod prête en 25,6 à 31,2 s, la 3.10 en 33,8 à 40,1 s).

| Scénario | Mesure | Preuve |
|---|---|---|
| `helm create` contre notre chart | 12 fichiers, 539 lignes ; chart corrigé : **10 fichiers, 220 lignes** (premier chart : 10 fichiers, 181 lignes) | `01` |
| install dev (défauts) et prod (`values-prod.yaml`, `--wait`) | 2 releases, révision 1, `deployed` ; prod prête en **31,2 s** ; `Bonjour` / `Bienvenue` | `03` |
| `tag: 3.10` sans guillemets | `helm lint` : 0 échec ; `helm template` : `image: "orders:3.1"` | `04` |
| `helm upgrade` sans attente | rendu en **1,5 s**, `STATUS: deployed`, révision 2 ; 90 s après : 3 pods `3.9` prêts + 1 pod `3.1` **ImagePullBackOff** ; `/info` répond `3.9` | `04` |
| même erreur, `--rollback-on-failure --timeout 2m` | `UPGRADE FAILED … has been rolled back`, en **122,0 s** ; historique : 5 révisions (`failed` puis `Rollback to 3`) | `05` |
| `tag: "3.10"` | mise à jour attendue jusqu'au bout : **38,1 s**, 3 pods `3.10` | `06` |
| `--set message=Salut`, chart sans empreinte | ConfigMap = `Salut` ; 60 s après : même pod, 0 redémarrage, `/info` = **`Bonjour`** | `07` |
| même chose, chart avec `checksum/config` | pod remplacé, `/info` = `Salut` | `08` |
| prod (3.10, autoscaler 3-6) puis `upgrade --set message=Promo` sans `-f` | valeurs = `message: Promo` seul ; **version 3.9, 1 copie, autoscaler supprimé** | `09` |
| `upgrade` sans aucune valeur | reprend les valeurs de la révision précédente | `10` |
| `-f values-prod.yaml --set message=Promo` | 3.10, 3/3, autoscaler présent, `Promo` | `10` |
| chart naïf (`replicas: 3` + autoscaler), charge sur `/calcul` | 6 copies voulues à 46 s, prêtes à 67 s ; managedFields : `helm Apply`, `kube-controller-manager Update scale` | `11` |
| Helm 4 : `upgrade --set message=Promo` | **refusé** : conflit server-side apply sur `.spec.replicas` avec `kube-controller-manager` (sous-ressource `scale`) ; révision `failed` | `11` |
| Helm 4 : `--force-conflicts` | voulues=**3** de 1 à 10 s, 6 à 15 s ; prêtes=3 jusqu'à 20 s, 5 à 30 s, **6 à 45 s** | `11` |
| Helm 3.18.5 : même scénario | mise à jour **acceptée sans message**, mêmes chiffres que `--force-conflicts` (voulues=3 de 1 à 10 s, 6 prêtes à 45 s) | `11b` |
| chart corrigé (pas de `replicas` si autoscaling) | aucun conflit, voulues=6 à chaque relevé (prêtes=5 pendant le remplacement un par un, 6 à 45 s) | `12` |
| premier chart → chart corrigé, release existante, sans charge | `helm Apply` seul propriétaire de `replicas` ; après l'upgrade : **voulues=1 prêtes=1** à 1 et 3 s, prêtes=1 encore à 5 s, 2 à 10-15 s | `12b` |
| même chose après `kubectl apply --server-side --field-manager=handover-to-hpa` (replicas seul) | managedFields : `handover-to-hpa Apply` ; **jamais moins de 3 prêtes** | `12c` |
| YAML : `tag: 3.10`, `01000`, `0042` | `3.1`, **`512`**, **`34`** (octal) ; `"3.10"` reste `3.10` | `15` |
| `values.schema.json` du chart corrigé, `tag: 3.10` | `helm lint` : `at '/image/tag': got number, want string`, 1 chart en échec | `15` |
| mot de passe dans `values.yaml` | 4 Secrets `sh.helm.release.v1.orders.v1…v4` ; `helm get values --revision 1 --all` et décodage `base64 -d \| base64 -d \| gunzip` : `Sup3r-Secret` | `13` |
| après passage à `existingSecret` | révision 4 : 0 occurrence ; **révision 1 : toujours 1** (`--history-max` : 10 par défaut) | `13` |
| `--atomic` sous Helm 4 | `Flag --atomic has been deprecated, use --rollback-on-failure instead` | `14` |

Notes :
- Helm 4 installe en server-side apply ; une mise à jour garde la méthode de la release (doc Helm 4, « Overview »). Une
  release créée par Helm 3 reste donc en client-side apply après le passage à Helm 4 : le conflit du scénario 11 ne
  s'y produit pas, c'est le comportement de `11b`.
- Le scénario 11 se joue dans l'espace `prod`, après désinstallation de la release des scénarios précédents (une seule
  base par espace, et la mémoire de la VM).
- L'image `orders:3.1` n'existe ni dans le nœud ni sur Docker Hub : c'est ce qui fait échouer le tirage.
- En 12b et 12c, l'autoscaler monte ensuite à 6 copies sans charge : la mise à jour remplace les pods (nouveau modèle),
  et le démarrage des JVM fait passer le processeur au-dessus de 60 % de ce que chaque pod demande. Effet réel, à
  connaître : un déploiement de JVM peut déclencher l'autoscaler à lui seul.
- Pendant les scénarios de l'autoscaler, le pod du dev est arrêté (`replicas=0`) pour tenir dans la mémoire de la VM.
- La colonne `APP VERSION` de `helm list` / `helm history` affiche `appVersion` du chart (`3.9`), pas l'image déployée.
