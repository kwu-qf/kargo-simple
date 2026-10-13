#!/bin/bash

if [ -z "$1" ]; then
  echo "./download-cli.sh /usr/local/bin/kargo [version, e.g. v1.12.4]"
  exit 1
fi

# The CLI must match the Kargo server version (v1.12 removed the old gRPC API).
version=$2
if [ -z "$version" ]; then
  version=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/akuity/kargo/releases/latest))
fi
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
download_url=https://github.com/akuity/kargo/releases/download/${version}/kargo-${os}-${arch}

curl -L -o ${1} ${download_url}
chmod +x ${1}
