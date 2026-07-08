{{/*
_helpers.tpl — named template snippets reused across the chart.

Helm renders any file in templates/ into Kubernetes objects, EXCEPT files
starting with "_", which hold reusable helpers instead. Defining names and
labels once here (and `include`-ing them everywhere) keeps every object in the
release consistently named and labelled — the same discipline as a shared
function instead of copy-pasted strings.
*/}}

{{/*
Base name for the release's objects. Defaults to the chart name, but a release
can override it with fullnameOverride. Truncated to 63 chars (the Kubernetes
name limit) and trailing "-" trimmed.
*/}}
{{- define "url-shortener.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
The Postgres objects hang off the same base name with a "-postgres" suffix, so
the StatefulSet, its headless Service, and the app's POSTGRES_HOST all agree on
one DNS name — and two releases in different namespaces never collide.
*/}}
{{- define "url-shortener.postgres.fullname" -}}
{{- printf "%s-postgres" (include "url-shortener.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels every object carries. The app.kubernetes.io/* keys are the Kubernetes
"recommended labels" — standard metadata that tools (kubectl, Argo CD, Grafana)
use to group an app's objects. instance = the release, so dev and prod stay
distinguishable.
*/}}
{{- define "url-shortener.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: url-shortener
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Selector labels — the stable subset used to match pods to their Deployment/
Service. These must never change for a running object (they're immutable on a
Deployment's selector), so they deliberately exclude version/chart labels.
*/}}
{{- define "url-shortener.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Postgres gets its own component selector so its Service targets only the
database pod, not the app pods.
*/}}
{{- define "url-shortener.postgres.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: postgres
{{- end -}}
