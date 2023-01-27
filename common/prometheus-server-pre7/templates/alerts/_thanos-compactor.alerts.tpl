groups:
- name: thanos-compactor.alerts
  rules:
    - alert: ThanosCompactMultipleRunning
      expr: sum by (prometheus) (up{job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"}) > 1
      for: 5m
      labels:
        service: {{ default "metrics" .Values.alerts.service }}
        support_group: {{ default "observability" .Values.alerts.support_group }}
        severity: warning
        meta: Multiple Thanos compactors running for `{{`{{ $labels.prometheus }}`}}`.
      annotations:
        description: |
          No more than one Thanos Compact instance should be running
          at once for `{{`{{ $labels.prometheus }}`}}`.
          Metrics in long term storage may be corrupted.
        summary: Thanos Compact has multiple instances running.

    - alert: ThanosCompactHalted
      expr: thanos_compact_halted{job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"} == 1
      for: 5m
      labels:
        service: {{ default "metrics" .Values.alerts.service }}
        support_group: {{ default "observability" .Values.alerts.support_group }}
        severity: info
        playbook: 'docs/support/playbook/prometheus/thanos_compaction.html'
        meta: Thanos Compact `{{`{{ $labels.prometheus }}`}}` has failed to run and is now halted.
      annotations:
        description: |
          Thanos Compact `{{`{{ $labels.prometheus }}`}}` has
          failed to run and is now halted.
          Long term storage queries will be slower.
        summary: Thanos Compact has failed to run and is now halted.

    - alert: ThanosCompactHighCompactionFailures
      expr: |
        (
          sum by (prometheus) (rate(thanos_compact_group_compactions_failures_total{job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"}[5m]))
        /
          sum by (prometheus) (rate(thanos_compact_group_compactions_total{job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"}[5m]))
        * 100 > 5
        )
      for: 15m
      labels:
        service: {{ default "metrics" .Values.alerts.service }}
        support_group: {{ default "observability" .Values.alerts.support_group }}
        severity: info
        playbook: 'docs/support/playbook/prometheus/thanos_compaction.html'
        meta: Thanos Compact `{{`{{ $labels.prometheus }}`}}` is failing to execute compactions.
      annotations:
        description: |
          Thanos Compact `{{`{{ $labels.prometheus }}`}}` is failing to execute
          `{{`{{ $value | humanize }}`}}%`of compactions.
          Long term storage queries will be slower.
        summary: Thanos Compact is failing to execute compactions.

    - alert: ThanosCompactBucketHighOperationFailures
      expr: |
        (
          sum by (prometheus) (rate(thanos_objstore_bucket_operation_failures_total{job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"}[5m]))
        /
          sum by (prometheus) (rate(thanos_objstore_bucket_operations_total{job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"}[5m]))
        * 100 > 5
        )
      for: 15m
      labels:
        service: {{ default "metrics" .Values.alerts.service }}
        support_group: {{ default "observability" .Values.alerts.support_group }}
        severity: info
        playbook: 'docs/support/playbook/prometheus/thanos_compaction.html'
        meta: Thanos Compact `{{`{{ $labels.prometheus }}`}}` bucket is having a high number of operation failures.
      annotations:
        description: |
          Thanos Compact `{{`{{ $labels.prometheus }}`}}` Bucket is failing
          to execute `{{`{{ $value | humanize }}`}}%` operations.
          Long term storage queries will be slower.
        summary: Thanos Compact Bucket is having a high number of operation failures.

    - alert: ThanosCompactHasNotRun
      expr: (time() - max by (prometheus) (max_over_time(thanos_objstore_bucket_last_successful_upload_time{job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"}[24h])))
        / 60 / 60 > 24
      labels:
        service: {{ default "metrics" .Values.alerts.service }}
        support_group: {{ default "observability" .Values.alerts.support_group }}
        severity: info
        playbook: 'docs/support/playbook/prometheus/thanos_compaction.html'
        meta: Thanos Compact `{{`{{ $labels.prometheus }}`}}` has not uploaded anything for last 24 hours.
      annotations:
        description: |
          Thanos Compact `{{`{{ $labels.prometheus }}`}}` has not
          uploaded anything for 24 hours.
          Long term storage queries will be slower.
        summary: Thanos Compact has not uploaded anything for last 24 hours.

    - alert: ThanosCompactIsDown
      expr: up{job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"} == 0 or absent({job=~".*thanos.*compact.*", prometheus="{{ include "prometheus.name" . }}"})
      for: 5m
      labels:
        no_alert_on_absence: "true" # because the expression already checks for absence
        service: {{ default "metrics" .Values.alerts.service }}
        support_group: {{ default "observability" .Values.alerts.support_group }}
        severity: warning
        playbook: docs/support/playbook/prometheus/thanos_compaction.html
        meta: Thanos Compact `{{`{{ $labels.prometheus }}`}}` has disappeared.
      annotations:
        description: |
          Thanos Compact `{{`{{ $labels.prometheus }}`}}` has disappeared.
          Prometheus target for the component cannot be discovered.
        summary: Thanos component has disappeared.
