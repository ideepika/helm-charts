input {

{{ range $key, $value := .Values.hermes.rabbitmq.targets }}
{{- $user := $value.user | default $.Values.hermes.rabbitmq.user }}
{{- $host := printf "%s-rabbitmq.monsoon3.svc.kubernetes.%s.%s" $key $.Values.global.region $.Values.global.tld}}
rabbitmq {
    id => {{ printf "logstash_hermes_%s" $key | quote }}
    host => {{ $value.host | default (printf $.Values.hermes.rabbitmq.host_template $key) | quote }}
    user => {{ $user | quote }}
    password => {{ $value.password | quote }}
    port => {{ $.Values.hermes.rabbitmq.port }}
    queue => {{ $value.queue_name | default $.Values.hermes.rabbitmq.queue_name | quote }}
    subscription_retry_interval_seconds => 60
    automatic_recovery => true
    heartbeat => 30
    connect_retry_interval => 60
    durable => {{ $value.durable | default false }}
  }
{{ end }}
}


filter {
  # unwrap messagingv2 envelope
  if [oslo.message] {
    json { source => "oslo.message" }
  }
  # Strip oslo header
  ruby {
    code => "
      v1pl = event.get('payload')
      if !v1pl.nil?
        v1pl.each {|k, v|
          event.set(k, v)
        }
        event.remove('payload')
      end
    "
  }
  # remove all the oslo stuff
  mutate {
    remove_field => [ "oslo.message", "oslo.version", "publisher_id", "event_type", "message_id", "priority", "timestamp" ]
  }

  # KEYSTONE TRANSFORMATIONS

  mutate {
     gsub => [
        # use proper CADF taxonomy for actions
        "action", "created\.", "create/",
        "action", "deleted\.", "delete/",
        "action", "updated\.", "create/",
        "action", "disabled\.", "disable/",
        "action", "\.", "/",
        # fix the eventTime format to be ISO8601
        "eventTime", '([+\-]\d\d)(\d\d)$', '\1:\2'
     ]
  }

  # Keystone specific transformations to compensate for scope missing from initiator element
  # When scope is missing from initiator, get it from action-specific parameters
  if ![initiator][project_id] and ![initiator][domain_id] {
    if [project] {
      mutate { add_field => { "%{[initiator][project_id]}" => "%{[project]}" } }
    } else if [domain] {
      mutate { add_field => { "%{[initiator][domain_id]}" => "%{[domain]}" } }
    }
  }

  # rename initiator user_id into the 'id' field for consistency
  if [initiator][user_id] {
    mutate {
      replace => { "[initiator][id]" => "%{[initiator][user_id]}" }
      remove_field => ["[initiator][user_id]"]
    }
  }

  # normalize role-assignment call eventsi
  # see https://sourcegraph.com/github.com/openstack/keystone@81f9fe6fed62ec629804c9367fbb9ebfd584388c/-/blob/keystone/notifications.py#L590
  if [project] {
    mutate {
      replace => { "[target][project_id]" => "%{[project]}" }
      remove_field => ["[project]"]
    }
  } else if [domain] {
    mutate {
      replace => { "[target][domain_id]" => "%{[domain]}" }
      remove_field => ["[domain]"]
    }
  }
  if [role] {
    ruby {
      code => "
        attachments = event.get('[attachments]')
        if attachments.nil?
          attachments = []
        end
        attachments << { 'name' => 'role_id', 'typeURI' => '/data/security/role', 'content' => event.get('role') }
        event.set('[attachments]', attachments)
      "
    }
  }
  if [group] {
    ruby {
      code => "
        attachments = event.get('[attachments]')
        if attachments.nil?
          attachments = []
        end
        attachments << { 'name' => 'group_id', 'typeURI' => '/data/security/group', 'content' => event.get('group') }
        event.set('[attachments]', attachments)
      "
    }
  }
  if [inherited_to_projects] {
    ruby {
      code => "
        attachments = event.get('[attachments]')
        if attachments.nil?
          attachments = []
        end
        attachments << { 'name' => 'inherited_to_projects', 'typeURI' => 'xs:boolean', 'content' => event.get('inherited_to_projects') }
        event.set('[attachments]', attachments)
      "
    }
  }

  # replace target ID with real user ID
  if [target][typeURI] == "service/security/account/user" and [user] {
     mutate {
       replace => { "[target][id]" => "%{[user]}" }
       remove_field => ["[user]"]
     }
  }

  # Enrich keystone events with domain mapping from Metis
  if [initiator][id] or [initiator][project_id] {
    jdbc_static {
      id => "jdbc"
      loaders => [
        {
          id  => "keystone_user_domain"
          query => "select u.id as user_id, m.local_id as user_name, p.id as domain_id, p.name as domain_name  from keystone.user as u left join keystone.id_mapping m on m.public_id = u.id left join keystone.project as p on p.id = u.domain_id where p.name = 'ccadmin'"
          local_table => "user_domain_mapping"
        },
        {
          id  => "keystone_project_domain"
          query => "select project.name as project_name, project.id as project_id, domain.name as domain_name, domain.id as domain_id from keystone.project join keystone.project domain on project.domain_id = domain.id where project.id = 'ccadmin'"
          local_table => "project_domain_mapping"
        }
      ]

      local_db_objects => [
        {
          name => "user_domain_mapping"
          index_columns => ["user_id"]
          columns => [
            ["user_id", "varchar(64)"],
            ["user_name", "varchar(64)"],
            ["domain_id", "varchar(64)"],
            ["domain_name", "varchar(64)"]
          ]
        },
        {
          name => "project_domain_mapping"
          index_columns => ["project_id"]
          columns => [
            ["project_name", "varchar(64)"],
            ["project_id", "varchar(64)"],
            ["domain_name", "varchar(64)"],
            ["domain_id", "varchar(64)"]
          ]
        }
      ]

      local_lookups => [
        {
          id => "domain_lookup"
          query => "select user_name, domain_id, domain_name from user_domain_mapping where user_id = ?"
          prepared_parameters => ["[initiator][id]"]
          target => "domain_mapping"
        },
        {
          id => "project_name_lookup"
          query => "select project_name, domain_id, domain_name from project_domain_mapping where project_id = ?"
          prepared_parameters => ["[initiator][project_id]"]
          target => "project_mapping"
        },
        {
          id => "project_target_lookup"
          query => "select project_name, domain_id, domain_name from project_domain_mapping where project_id = ?"
          prepared_parameters => ["[target][project_id]"]
          target => "project_target_mapping"
        }
      ]
      staging_directory => "/tmp/logstash/jdbc_static/import_data"
      loader_schedule => "{{ .Values.logstash.jdbc.schedule }}"
      jdbc_user => "{{ .Values.global.metis.user }}"
      jdbc_password => "${METIS_PASSWORD}"
      jdbc_driver_class => "com.mysql.cj.jdbc.Driver"
      jdbc_driver_library => ""
      jdbc_connection_string => "jdbc:mysql://{{ .Values.logstash.jdbc.service }}.{{ .Values.logstash.jdbc.namespace }}:3306/{{ .Values.logstash.jdbc.db }}"
    }

    if [domain_mapping] and [domain_mapping][0]{
      # Add Fields to audit events, checking if the field exists first to not overwrite.
      if ![initiator][name] {
        mutate {
          add_field => {
              "[initiator][name]" => "%{[domain_mapping][0][user_name]}"
          }
        }
      }
      if ![initiator][domain_id] {
        mutate {
          add_field => {
              "[initiator][domain_id]" => "%{[domain_mapping][0][domain_id]}"
          }
        }
      }
      if ![initiator][domain] {
        mutate {
          add_field => {
              "[initiator][domain]" => "%{[domain_mapping][0][domain_name]}"
          }
        }
      }
      # Cleanup
      mutate {
        remove_field => [ "domain_mapping" ]
      }
    }

    if [project_mapping] and [project_mapping][0]{
      # Add Fields to audit events, checking if the field exists first to not overwrite.
      if ![initiator][project] {
        mutate {
          add_field => {
              "[initiator][project]" => "%{[project_mapping][0][project_name]}"
          }
        }
      }
      if ![initiator][domain_id] {
        mutate {
          add_field => {
              "[initiator][domain_id]" => "%{[project_mapping][0][domain_id]}"
          }
        }
      }
      if ![initiator][project_domain_name] {
        mutate {
          add_field => {
              "[initiator][project_domain_name]" => "%{[project_mapping][0][domain_name]}"
          }
        }
      }

      # Cleanup
      mutate {
        remove_field => [ "project_mapping" ]
      }
    }

    if [project_target_mapping] and [project_target_mapping][0]{
      # Add Fields to audit events, checking if the field exists first to not overwrite.
      if ![target][project] {
        mutate {
          add_field => {
              "[target][project]" => "%{[project_target_mapping][0][project_name]}"
          }
        }
      }
      if ![target][domain_id] {
        mutate {
          add_field => {
              "[target][domain_id]" => "%{[project_target_mapping][0][domain_id]}"
          }
        }
      }
      if ![target][project_domain_name] {
        mutate {
          add_field => {
              "[target][project_domain_name]" => "%{[project_target_mapping][0][domain_name]}"
          }
        }
      }

      # Cleanup
      mutate {
        remove_field => [ "project_target_mapping" ]
      }
    }
  }

  # Octobus setting Source to TypeURI. Unused in Hermes.
  if [observer][typeURI] {
    mutate {
        add_field => {  "[sap][cc][audit][source]" => "%{[observer][typeURI]}" }
    }
  }

  # Clean up any null or empty string fields
  ruby {
    init => "
        def removeEmptyField(event,h,name)
            h.each do |k,v|
                    if (v.is_a?(Hash) || v.is_a?(Array)) && v.to_s != '{}'
                        removeEmptyField(event,v,String.new(name.to_s) << '[' << k.to_s << ']')
                    else
                    if v == '' || v.to_s == '{}' || v == '-'
                        event.remove(String.new(name.to_s) << '[' << k.to_s << ']')
                    end
                end
            end
        end
    "
    code => "
        removeEmptyField event,event.to_hash,''
    "
  }

  # Calculate the variable index name part from payload (@metadata will not be part of the event)

  # primary index
  if [initiator][project_id] {
    mutate { add_field => { "[@metadata][index]" => "%{[initiator][project_id]}" } }
  } else if [initiator][domain_id] {
    mutate { add_field => { "[@metadata][index]" => "%{[initiator][domain_id]}" } }
  }

  # secondary index
  if [target][project_id] {
    mutate { add_field => { "[@metadata][index2]" => "%{[target][project_id]}" } }
  } else if [target][domain_id] {
    mutate { add_field => { "[@metadata][index2]" => "%{[target][domain_id]}" } }
  }

  # remove keystone specific fields after they have been mapped to standard attachments
  mutate {
    remove_field => ["[domain]", "[project]", "[user]", "[role]", "[group]", "[inherited_to_projects]"]
  }

  kv { source => "_source" }

  # The following line will create 2 additional
  # copies of each document (i.e. including the
  # original, 3 in total).
  # Each copy will automatically have a "type" field added
  # corresponding to the name given in the array.
  clone {
    clones => ['clone_for_audit', 'clone_for_swift', 'clone_for_cc', 'audit']
  }
}

output {
  if [type] == 'clone_for_audit' {
    if ([@metadata][index]) {
      elasticsearch {
          index => "audit-%{[@metadata][index]}-6-%{+YYYY.MM}"
          template => "/hermes-etc/audit.json"
          template_name => "audit"
          template_overwrite => true
          hosts => ["{{.Values.hermes_elasticsearch_host}}:{{.Values.hermes_elasticsearch_port}}"]
          # retry_max_interval default 64
          retry_max_interval => 10
      }
    } else {
      elasticsearch {
          index => "audit-default-6-%{+YYYY.MM}"
          template => "/hermes-etc/audit.json"
          template_name => "audit"
          template_overwrite => true
          hosts => ["{{.Values.hermes_elasticsearch_host}}:{{.Values.hermes_elasticsearch_port}}"]
          # retry_max_interval default 64
          retry_max_interval => 10
      }
    }
  }
  # cc the target tenant
  if ([@metadata][index2] and [@metadata][index2] != [@metadata][index] and [type] == 'clone_for_cc') {
    elasticsearch {
        index => "audit-%{[@metadata][index2]}-6-%{+YYYY.MM}"
        template => "/hermes-etc/audit.json"
        template_name => "audit"
        template_overwrite => true
        hosts => ["{{.Values.hermes_elasticsearch_host}}:{{.Values.hermes_elasticsearch_port}}"]
        # retry_max_interval default 64
        retry_max_interval => 10
    }
  }

  {{ if .Values.logstash.swift -}}
  if [type] == 'clone_for_swift' {
    s3{
      endpoint => "{{.Values.logstash.endpoint}}"
      access_key_id => "{{.Values.logstash.access_key_id}}"
      secret_access_key => "{{.Values.logstash.secret_access_key}}"
      region => "{{.Values.logstash.region}}"
      bucket => "{{.Values.logstash.bucket}}"
      prefix => "{{.Values.logstash.prefix}}"
      time_file => {{.Values.logstash.time_file}}
      #encoding => "gzip"
      codec => "json_lines"
      validate_credentials_on_root_bucket => false
      additional_settings => {
        "force_path_style" => true
      }
    }
  }
  {{- end}}

  {{ if .Values.logstash.audit -}}
  if [type] == 'audit' {
    if [initator][domain] == 'ccadmin' or ([observer][typeURI] == "service/security" and [action] == "authenticate" and [outcome] == "failure") {
      http{
        url => "https://logstash-audit-external.{{.Values.global.region}}.{{.Values.global.tld}}"
        format => "json"
        http_method => "post"
        headers => { "Authorization" =>  "Basic {{ template "httpBasicAuth" . }}" }
      }
    }
  }
  {{- end}}
}
