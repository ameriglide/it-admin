#!/usr/bin/env bash
# install-vector-host-metrics.sh
# Installs Vector as a native systemd service shipping host_metrics (CPU / RAM /
# disk / network) to a Better Stack telemetry source. This is the Linux
# counterpart to install-vector-host-metrics.ps1 and mirrors the known-good
# sage-amg pipeline: host_metrics -> metric_to_log -> remap -> http "/metrics".
#
# Deliberately native (single static binary + systemd unit), NOT the Better
# Stack collector: the collector requires Docker, and installing the Docker
# engine rewrites iptables in ways that collide with Tailscale's chains and can
# knock the host off the tailnet. This installer touches no iptables, no Docker,
# no eBPF -- just one outbound HTTPS connection.
#
# All hosts ship to ONE shared "Host metrics (Vector)" source and are told apart
# by a host= tag (set via --host-name, default = the box's hostname), so a single
# fleet dashboard can group/roll up by host and one alert can cover every host.
#
# Usage (run as root on the target host):
#   curl -fsSL https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/install-vector-host-metrics.sh \
#     | bash -s -- --source-token <SHARED_TOKEN> --ingest-host s<ID>.us-east-9.betterstackdata.com --host-name amg-bjx
set -euo pipefail

SOURCE_TOKEN=""
INGEST_HOST=""
HOST_NAME=""
VECTOR_VERSION="${VECTOR_VERSION:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-token) SOURCE_TOKEN="$2"; shift 2 ;;
    --ingest-host)  INGEST_HOST="$2";  shift 2 ;;
    --host-name)    HOST_NAME="$2";    shift 2 ;;
    --vector-version) VECTOR_VERSION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Default the host tag to the box's own hostname if not given explicitly.
HOST_NAME="${HOST_NAME:-$(hostname -s 2>/dev/null || hostname)}"

if [[ -z "$SOURCE_TOKEN" || -z "$INGEST_HOST" ]]; then
  echo "ERROR: --source-token and --ingest-host are both required" >&2
  exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (writes /opt/vector, /etc/vector, systemd unit)" >&2
  exit 1
fi

INSTALL_DIR=/opt/vector
BIN=$INSTALL_DIR/bin/vector
CONFIG=/etc/vector/vector.yaml
UNIT=/etc/systemd/system/vector.service

# --- 1. Install the Vector binary (idempotent) -------------------------------
if [[ ! -x "$BIN" ]]; then
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) echo "ERROR: unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac

  if [[ -z "$VECTOR_VERSION" ]]; then
    # Resolve the latest release tag (e.g. "v0.49.0"); fall back to a pin.
    VECTOR_VERSION="$(curl -fsSL https://api.github.com/repos/vectordotdev/vector/releases/latest 2>/dev/null \
      | grep -m1 '"tag_name"' | sed -E 's/.*"v?([0-9.]+)".*/\1/')" || true
  fi
  VECTOR_VERSION="${VECTOR_VERSION:-0.49.0}"

  tarball="vector-${ARCH}-unknown-linux-gnu.tar.gz"
  url="https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-${ARCH}-unknown-linux-gnu.tar.gz"
  echo "Installing Vector ${VECTOR_VERSION} (${ARCH})..."
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/$tarball"
  tar -xzf "$tmp/$tarball" -C "$tmp"
  src="$(dirname "$(dirname "$(find "$tmp" -type f -name vector -path '*/bin/*' | head -1)")")"
  [[ -n "$src" ]] || { echo "ERROR: vector binary not found in archive" >&2; exit 1; }
  mkdir -p "$INSTALL_DIR"
  cp -a "$src/." "$INSTALL_DIR/"
else
  echo "Vector already present at $BIN"
fi

# --- 2. Write the config (always; mirrors the working sage-amg pipeline) ------
mkdir -p /etc/vector /var/lib/vector
cat > "$CONFIG" <<EOF
# Better Stack host metrics (managed by it-admin install-vector-host-metrics.sh)
data_dir: /var/lib/vector

sources:
  better_stack_host_metrics:
    type: host_metrics
    scrape_interval_secs: 30
    collectors: [cpu, disk, filesystem, memory, network]

transforms:
  better_stack_host_metrics_log:
    type: metric_to_log
    inputs: ["better_stack_host_metrics"]
  better_stack_host_metrics_parser:
    type: remap
    inputs: ["better_stack_host_metrics_log"]
    source: |
      del(.source_type)
      .dt = del(.timestamp)
      .tags.host = "${HOST_NAME}"

sinks:
  better_stack_metrics:
    type: http
    method: post
    uri: "https://${INGEST_HOST}/metrics"
    encoding:
      codec: json
    compression: gzip
    auth:
      strategy: bearer
      token: "${SOURCE_TOKEN}"
    inputs: ["better_stack_host_metrics_parser"]
EOF
chmod 600 "$CONFIG"

# --- 3. systemd unit ---------------------------------------------------------
cat > "$UNIT" <<EOF
[Unit]
Description=Vector (Better Stack host metrics)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN --config $CONFIG
Restart=always
RestartSec=5
User=root
Environment=VECTOR_LOG=warn

[Install]
WantedBy=multi-user.target
EOF

# --- 4. Validate, enable, (re)start ------------------------------------------
"$BIN" validate "$CONFIG"
systemctl daemon-reload
systemctl enable vector >/dev/null 2>&1 || true
systemctl restart vector
sleep 2
systemctl --no-pager --full status vector | head -8 || true
echo "  Vector host_metrics installed and started -> https://${INGEST_HOST}/metrics"
