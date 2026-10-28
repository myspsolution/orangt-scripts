#!/usr/bin/env bash
sudo apt update
sudo apt install -y curl ca-certificates git

GO_VERSION="1.26.5"

case "$(dpkg --print-architecture)" in
    amd64)
        GO_ARCH="amd64"
        GO_SHA256="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
        ;;
    arm64)
        GO_ARCH="arm64"
        GO_SHA256="fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49"
        ;;
    *)
        echo "Unsupported architecture: $(dpkg --print-architecture)"
        exit 1
        ;;
esac

cd /tmp

curl -fLO "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

echo "${GO_SHA256}  go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" \
    | sha256sum --check -

sudo rm -rf /usr/local/go

sudo tar -C /usr/local \
    -xzf "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

sudo tee /etc/profile.d/go.sh >/dev/null <<'EOF'
export PATH="/usr/local/go/bin:$PATH"
export PATH="$HOME/go/bin:$PATH"
EOF

sudo chmod 644 /etc/profile.d/go.sh

source /etc/profile.d/go.sh

go version
go env GOROOT GOPATH

rm -f "/tmp/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
