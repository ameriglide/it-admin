#!/usr/bin/env bash
# Builds guacd against a current upstream FreeRDP into an isolated prefix on
# the Guacamole portal host, without touching the running guacd.
#
# Why: AL2023 ships freerdp-libs 3.6.3. guacd linked against it SIGABRTs on
# essentially every connection teardown (WINPR_ASSERT in drdynvc
# check_open_close_receive <- dvcman_channel_close), and 3.6.3 carries
# CVE-2026-56297, a race in that same code fixed in 3.22.0. See AG-1356.
#
# Everything lands under $PREFIX with an rpath, so the system FreeRDP RPM and
# the old /usr/local guacd stay as they are. Switching is a systemd drop-in
# (see README.md, "Upgrading FreeRDP"); rolling back is deleting it.
#
# Usage (as root on the portal):
#   build-guacd.sh [FREERDP_VERSION] [GUAC_VERSION]
set -euo pipefail

# 3.30.x is the newest FreeRDP that guacamole-server 1.6.0 works with. 3.31.0
# moved the GDI cache setup, and 1.6.0 calls gdi_init() from PreConnect, so
# every connection aborts in gdi_init_ex() (fixed upstream in GUACAMOLE-2328,
# unreleased as of 2026-10; seen on the canary 2026-10-23). Move past 3.30
# only together with a guacamole-server release that includes that fix.
FREERDP_VERSION="${1:-3.30.0}"
GUAC_VERSION="${2:-1.6.0}"
PREFIX="${PREFIX:-/opt/guacd/freerdp-${FREERDP_VERSION}}"
SRC="${SRC:-/usr/local/src/guacd-build}"
JOBS="${JOBS:-2}"     # keep cores free for live sessions while building
GUACD_TIMEOUT_MS="${GUACD_TIMEOUT_MS:-120000}"   # upstream is 15000; see below

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

dnf install -y --setopt=install_weak_deps=False \
  gcc gcc-c++ make cmake pkgconf tar gzip \
  openssl-devel zlib-devel \
  cairo-devel libjpeg-turbo-devel libpng-devel libuuid-devel libwebp-devel \
  pango-devel libssh2-devel libvorbis-devel pulseaudio-libs-devel \
  libtool autoconf automake

mkdir -p "$SRC"
cd "$SRC"

# --- FreeRDP ---------------------------------------------------------------
if [ ! -d "freerdp-${FREERDP_VERSION}" ]; then
  curl -fsSLO "https://github.com/FreeRDP/FreeRDP/releases/download/${FREERDP_VERSION}/freerdp-${FREERDP_VERSION}.tar.gz"
  tar xzf "freerdp-${FREERDP_VERSION}.tar.gz"
fi
# Client libraries only: guacd is the client, there is no local display, and
# Guacamole handles audio/printing/drive itself.
cmake -S "freerdp-${FREERDP_VERSION}" -B "freerdp-${FREERDP_VERSION}/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
  -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_PLATFORM_SERVER=OFF \
  -DWITH_SAMPLE=OFF -DWITH_MANPAGES=OFF \
  -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_CLIENT_SDL=OFF -DWITH_WEBVIEW=OFF \
  -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF \
  -DWITH_CUPS=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF \
  -DWITH_PCSC=OFF -DWITH_PKCS11=OFF -DWITH_FUSE=OFF -DCHANNEL_URBDRC=OFF \
  -DWITH_FDK_AAC=OFF -DWITH_OPUS=OFF -DWITH_SOXR=OFF -DWITH_LAME=OFF -DWITH_FAAD2=OFF \
  -DWITH_KRB5=OFF -DWITH_UNICODE_BUILTIN=ON \
  -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF   # JSON is only for Azure AD login
nice -n 19 cmake --build "freerdp-${FREERDP_VERSION}/build" -j "$JOBS"
cmake --install "freerdp-${FREERDP_VERSION}/build"

# --- guacamole-server --------------------------------------------------------
if [ ! -d "guacamole-server-${GUAC_VERSION}" ]; then
  curl -fsSL -o "guacamole-server-${GUAC_VERSION}.tar.gz" \
    "https://archive.apache.org/dist/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz"
  tar xzf "guacamole-server-${GUAC_VERSION}.tar.gz"
fi
cd "guacamole-server-${GUAC_VERSION}"
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true

# guacd drops a user after GUACD_TIMEOUT ms with no inbound data ("User is
# not responding."). Upstream's 15s is shorter than the ~60s timer wake-up
# Chrome/Edge allow a tab hidden for a few minutes, so the client's 5s nop
# keep-alive stalls and every user who switches to another app for a while
# gets dropped. Reproduced 2026-10-23: hidden at 14:55:18, dropped 14:59:40.
sed -i -E "s/^#define GUACD_TIMEOUT [0-9]+/#define GUACD_TIMEOUT ${GUACD_TIMEOUT_MS}/" src/guacd/proc.h
grep -q "^#define GUACD_TIMEOUT ${GUACD_TIMEOUT_MS}\$" src/guacd/proc.h \
  || { echo "failed to set GUACD_TIMEOUT in src/guacd/proc.h" >&2; exit 1; }
# The rpath matters twice: guacd's direct deps, and libguac's dlopen() of
# libguac-client-rdp.so, which resolves against libguac's own RUNPATH -- so the
# new guacd never picks up the old /usr/local/lib client plugins.
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
LDFLAGS="-Wl,-rpath,$PREFIX/lib" \
CFLAGS="-O2 -Wno-error=deprecated-declarations" \
  ./configure --prefix="$PREFIX" \
    --with-freerdp-plugin-dir="$PREFIX/lib/freerdp3" \
    --disable-guacenc --disable-guaclog \
    --without-vnc --without-telnet --without-kubernetes
nice -n 19 make -j "$JOBS"
make install

echo
echo "Built: $PREFIX/sbin/guacd"
"$PREFIX/sbin/guacd" -v
ldd "$PREFIX/sbin/guacd" "$PREFIX/lib/libguac-client-rdp.so" | grep -E "freerdp|winpr|guac" | sort -u
