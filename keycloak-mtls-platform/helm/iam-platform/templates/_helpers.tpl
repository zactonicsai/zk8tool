{{/*
=============================================================================
Named templates shared by all manifests. Docs: docs/helm/helpers.md

Naming contract with scripts/lib/common.sh and scripts/lib/k8s.sh:
  <fullname>-keycloak           Keycloak StatefulSet / Service
  <fullname>-spring-app         App Deployment / Service
  <fullname>-test-client        helm test pod
  <fullname>-<component>-tls    TLS Secrets (tls.crt, tls.key, ca.crt)
=============================================================================
*/}}

{{- define "platform.fullname" -}}
{{- .Values.fullnameOverride | default .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "platform.keycloak.fullname" -}}
{{- printf "%s-keycloak" (include "platform.fullname" .) -}}
{{- end -}}

{{- define "platform.app.fullname" -}}
{{- printf "%s-spring-app" (include "platform.fullname" .) -}}
{{- end -}}

{{- define "platform.testClient.fullname" -}}
{{- printf "%s-test-client" (include "platform.fullname" .) -}}
{{- end -}}

{{- define "platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels. Usage: {{ include "platform.labels" (dict "root" . "component" "keycloak") }}
*/}}
{{- define "platform.labels" -}}
helm.sh/chart: {{ include "platform.chart" .root }}
{{ include "platform.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/part-of: {{ .root.Chart.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels: stable for the lifetime of a release (selectors are immutable).
*/}}
{{- define "platform.selectorLabels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "platform.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "platform.fullname" .) -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{/*
Image reference. A digest wins over the tag; the tag defaults to appVersion.
Usage: {{ include "platform.image" (dict "root" . "image" .Values.keycloak.image) }}
*/}}
{{- define "platform.image" -}}
{{- $repository := .image.repository -}}
{{- if .root.Values.global.imageRegistry -}}
{{- $repository = printf "%s/%s" (trimSuffix "/" .root.Values.global.imageRegistry) .image.repository -}}
{{- end -}}
{{- if .image.digest -}}
{{- printf "%s@%s" $repository .image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repository (.image.tag | default .root.Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{- define "platform.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
URLs. "internal" is the in-cluster Service URL used for back-channel calls;
"public" is what browsers use and what Keycloak puts into tokens as issuer.
*/}}
{{- define "platform.keycloak.host" -}}
{{- printf "%s.%s.svc.%s" (include "platform.keycloak.fullname" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}

{{- define "platform.keycloak.internalUrl" -}}
{{- printf "https://%s:%v" (include "platform.keycloak.host" .) .Values.keycloak.service.port -}}
{{- end -}}

{{- define "platform.keycloak.publicUrl" -}}
{{- .Values.keycloak.publicUrl | default (include "platform.keycloak.internalUrl" .) | trimSuffix "/" -}}
{{- end -}}

{{- define "platform.keycloak.managementUrl" -}}
{{- printf "https://%s:%v" (include "platform.keycloak.host" .) .Values.keycloak.service.managementPort -}}
{{- end -}}

{{- define "platform.app.host" -}}
{{- printf "%s.%s.svc.%s" (include "platform.app.fullname" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}

{{- define "platform.app.internalUrl" -}}
{{- printf "https://%s:%v" (include "platform.app.host" .) .Values.app.service.port -}}
{{- end -}}

{{- define "platform.app.publicUrl" -}}
{{- .Values.app.publicUrl | default (include "platform.app.internalUrl" .) | trimSuffix "/" -}}
{{- end -}}

{{- define "platform.app.managementUrl" -}}
{{- printf "https://%s:%v" (include "platform.app.host" .) .Values.app.service.managementPort -}}
{{- end -}}

{{/* SAML entity id of the app; must equal the clientId of the SAML client in the realm. */}}
{{- define "platform.app.samlEntityId" -}}
{{- printf "%s/saml2/service-provider-metadata/keycloak" (include "platform.app.publicUrl" .) -}}
{{- end -}}

{{/* Host part of a URL: https://host:port/path -> host */}}
{{- define "platform.urlHost" -}}
{{- (urlParse .).host | splitList ":" | first -}}
{{- end -}}

{{/*
Certificate subject DN in RFC 2253 order, the form Keycloak compares.
Usage: {{ include "platform.subjectDn" (dict "root" . "cn" "spring-app") }}
*/}}
{{- define "platform.subjectDn" -}}
{{- $subject := .root.Values.certificates.subject -}}
{{- printf "CN=%s,OU=%s,O=%s,C=%s" .cn $subject.organizationalUnit $subject.organization $subject.country -}}
{{- end -}}

{{- define "platform.issuerDn" -}}
{{- .Values.certificates.issuerDn | default (include "platform.subjectDn" (dict "root" . "cn" .Values.certificates.caCommonName)) -}}
{{- end -}}

{{/* TLS Secret names. Usage: {{ include "platform.tlsSecretName" (dict "root" . "name" "keycloak") }} */}}
{{- define "platform.tlsSecretName" -}}
{{- printf "%s-%s-tls" (include "platform.fullname" .root) .name -}}
{{- end -}}

{{- define "platform.samlSecretName" -}}
{{- .Values.app.saml.signing.existingSecret | default (include "platform.tlsSecretName" (dict "root" . "name" "saml-sp")) -}}
{{- end -}}

{{- define "platform.keycloak.adminSecretName" -}}
{{- .Values.keycloak.admin.existingSecret | default (printf "%s-admin" (include "platform.keycloak.fullname" .)) -}}
{{- end -}}

{{/* Database port: explicit value or the vendor default. */}}
{{- define "platform.keycloak.databasePort" -}}
{{- $defaults := dict "postgres" 5432 "mariadb" 3306 "mysql" 3306 "mssql" 1433 "oracle" 1521 -}}
{{- .Values.keycloak.database.port | default (get $defaults .Values.keycloak.database.vendor) | default 5432 -}}
{{- end -}}

{{/* True when AuthnRequests are signed: enabled AND a certificate was supplied. */}}
{{- define "platform.app.samlSigning" -}}
{{- if .Values.app.saml.signing.enabled -}}
{{- if not .Values.app.saml.signing.certificate -}}
{{- fail "app.saml.signing.enabled is true but app.saml.signing.certificate is empty. Deploy with `platform.sh deploy` (which sets it), pass the base64 DER certificate yourself, or set app.saml.signing.enabled=false." -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{/* True unless certificates are baked into the images. */}}
{{- define "platform.mountCertificates" -}}
{{- if ne .Values.certificates.source "image" -}}true{{- end -}}
{{- end -}}

{{/*
Volume + mount for a component's TLS Secret (tls.crt, tls.key, ca.crt).
Group-readable only; the pod's fsGroup grants the container user access.
Usage: {{ include "platform.tlsVolume" (dict "root" . "name" "keycloak") }}
*/}}
{{- define "platform.tlsVolume" -}}
- name: tls
  secret:
    secretName: {{ include "platform.tlsSecretName" . }}
    defaultMode: 0440
{{- end -}}

{{- define "platform.tlsVolumeMount" -}}
- name: tls
  mountPath: /etc/platform/tls
  readOnly: true
{{- end -}}

{{/* Annotations that make Stakater Reloader restart pods when a mounted Secret changes. */}}
{{- define "platform.reloaderAnnotations" -}}
{{- if .Values.certificates.reloader }}
reloader.stakater.com/auto: "true"
{{- end }}
{{- end -}}

{{/* Guard rails evaluated once (included from NOTES.txt and the workloads). */}}
{{- define "platform.validate" -}}
{{- if and .Values.keycloak.enabled (ne .Values.keycloak.database.vendor "dev-file") -}}
{{- if not (or .Values.keycloak.database.url .Values.keycloak.database.host) -}}
{{- fail "keycloak.database.host (or keycloak.database.url) is required when keycloak.database.vendor is not dev-file." -}}
{{- end -}}
{{- if not .Values.keycloak.database.existingSecret -}}
{{- fail "keycloak.database.existingSecret (keys: username, password) is required when keycloak.database.vendor is not dev-file." -}}
{{- end -}}
{{- end -}}
{{- if and .Values.keycloak.enabled (eq .Values.keycloak.database.vendor "dev-file") (gt (int .Values.keycloak.replicas) 1) -}}
{{- fail "keycloak.replicas > 1 needs an external database; the embedded dev-file database cannot be shared." -}}
{{- end -}}
{{- end -}}
