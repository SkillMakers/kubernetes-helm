{{/* Étiquettes communes à tous les objets du chart. */}}
{{- define "orders.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "orders.tag" . | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Sélecteur : stable d'une version à l'autre (un Deployment refuse qu'on change son sélecteur). */}}
{{- define "orders.selector" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Étiquette de l'image : image.tag, sinon appVersion. */}}
{{- define "orders.tag" -}}
{{- .Values.image.tag | default .Chart.AppVersion -}}
{{- end }}
