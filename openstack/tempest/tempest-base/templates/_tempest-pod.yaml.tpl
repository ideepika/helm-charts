{{- define "tempest-base.tempest_pod" }}
apiVersion: v1
kind: Pod
metadata:
  name: {{ .Chart.Name }}
  labels:
    system: openstack
    type: configuration
spec:
  restartPolicy: Never
  containers:
    - name: {{ .Chart.Name }}
      image: {{ default "keppel.eu-de-1.cloud.sap/ccloud" .Values.global.registry}}/{{ default .Chart.Name (index .Values (print .Chart.Name | replace "-" "_")).tempest.imageNameOverride }}-plugin-python3:{{ default "latest" (index .Values (print .Chart.Name | replace "-" "_")).tempest.imageTag}}
      command:
        - kubernetes-entrypoint
      env:
        - name: COMMAND
          value: "/container.init/tempest-start-and-cleanup.sh"
        - name: NAMESPACE
          value: {{ .Release.Namespace }}
        - name: OS_REGION_NAME
          value: {{ required "Missing region value!" .Values.global.region }}
        - name: OS_USER_DOMAIN_NAME
          value: "tempest"
        - name: OS_PROJECT_DOMAIN_NAME
          value: "tempest"
        - name: OS_INTERFACE
          value: "internal"
        - name: OS_ENDPOINT_TYPE
          value: "internal"
        - name: OS_PASSWORD
          value: {{ .Values.tempestAdminPassword | quote }}
        - name: OS_IDENTITY_API_VERSION
          value: "3"
        - name: OS_AUTH_URL
          value: "https://identity-3.qa-de-1.cloud.sap/v3"
      resources:
        requests:
          memory: "1024Mi"
          cpu: "750m"
        limits:
          memory: "2048Mi"
          cpu: "1000m"
      volumeMounts:
        - mountPath: /{{ .Chart.Name }}-etc
          name: {{ .Chart.Name }}-etc
        - mountPath: /container.init
          name: container-init
  volumes:
    - name: {{ .Chart.Name }}-etc
      configMap:
        name: {{ .Chart.Name }}-etc
    - name: container-init
      configMap:
        name: {{ .Chart.Name }}-bin
        defaultMode: 0755
{{ end }}
