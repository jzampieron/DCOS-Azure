#!/bin/bash

set +o histexpand

# BOOTSTRAP_URL="$(hostname -I)"
BOOTSTRAP_URL=$1
DCOS_DOWNLOAD_URL=$2
DCOS_PASSWORD_HASH='$6$rounds=656000$83725EIL6U0tE/PU$1cJ9wGZ47q2QTQEZbMWK.uuXyB5CUirWRfBlQTDMnFsvH5l5sI50tdlH7TKYTzaPdVbsxix9NWrim1.y3Cfwf/' # Passw0rd

cd /opt/dcos

mkdir -p /opt/dcos/genconf

cat <<EOF > "/opt/dcos/genconf/config.yaml"
---
bootstrap_url: http://${BOOTSTRAP_URL}:80
cluster_name: 'dcos'
exhibitor_storage_backend: static
ip_detect_filename: /genconf/ip-detect
master_discovery: static
master_list:
- 172.16.0.10
- 172.16.0.11
- 172.16.0.12
- 172.16.0.13
- 172.16.0.14
# DNS on Azure is provided by the 168.63.129.16 Virtual IP
resolvers:
- 168.63.129.16
#- 8.8.8.8
#- 8.8.4.4
platform: azure
enable_docker_gc: 'true'
oauth_enabled: 'false'
telemetry_enabled: 'false'
superuser_username: 'admin'
superuser_password_hash: '${DCOS_PASSWORD_HASH}'
enable_docker_gc: 'true'
EOF

cat <<'EOF' > "/opt/dcos/genconf/ip-detect"
#!/usr/bin/env bash
set -o nounset -o errexit
ip route get 1|tr -s ' '|cut -f 7 -d ' '|tr -s '\n'
EOF

# curl -O https://downloads.dcos.io/dcos/stable/dcos_generate_config.sh
curl -O "${DCOS_DOWNLOAD_URL}"

sudo bash dcos_generate_config.sh

sudo docker run -d -p 80:80 -v /opt/dcos/genconf/serve:/usr/share/nginx/html:ro nginx:alpine
