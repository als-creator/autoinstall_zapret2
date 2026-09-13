#!/bin/bash
#
# Universal installer for zapret2 (bol-van/zapret2)
# Install to /opt/zapret2, build from source, auto-detect firewall type,
# write NFQWS2 rule (Lua strategies) + hostlists, create systemd unit,
# install config-switch tool, verify.
#
set -uo pipefail

log_ok(){ echo "[OK] $*"; }
log_warn(){ echo "[WARN] $*"; }
log_err(){ echo "[ERROR] $*"; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] && log_err "Не запускайте скрипт от root."
command -v sudo >/dev/null 2>&1 || log_err "sudo не установлен"
command -v git >/dev/null 2>&1 || log_err "git не установлен"

# ---------------------------------------------------------------------------
# Package manager detection
# ---------------------------------------------------------------------------
check_package_manager(){
    if   command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null;     then echo "dnf"
    elif command -v zypper &>/dev/null;  then echo "zypper"
    elif command -v yum &>/dev/null;     then echo "yum"
    elif command -v pacman &>/dev/null;  then echo "pacman"
    elif command -v apk &>/dev/null;     then echo "apk"
    elif command -v xbps-install &>/dev/null; then echo "xbps"
    else echo "unknown"; fi
}
PM=$(check_package_manager)
log_ok "Пакетный менеджер: $PM"

# ---------------------------------------------------------------------------
# Dependencies.
# Runtime:  curl ipset iptables|nftables gzip
# Build:    git make gcc pkg-config + dev headers (netfilter_queue, mnl, zlib,
#           cap, luajit2). systemd-devel only needed for the "systemd" make target,
#           which we do NOT use (unit is Type=forking), so it is optional.
# ---------------------------------------------------------------------------
get_pkg_lists(){
    case "$PM" in
        apt)  PKGS_RT="curl gzip ipset iptables"
              PKGS_BLD="git make gcc pkg-config libnetfilter-queue-dev libmnl-dev zlib1g-dev libcap-dev libluajit2-5.1-dev"
              ;;
        dnf|yum)
              PKGS_RT="curl gzip ipset iptables"
              PKGS_BLD="git make gcc pkgconfig libnetfilter_queue-devel libmnl-devel zlib-devel libcap-devel luajit-devel"
              ;;
        pacman) PKGS_RT="curl gzip ipset iptables"
              PKGS_BLD="git make gcc pkgconf libnetfilter_queue libmnl libcap luajit systemd"
              # zlib provided by zlib-ng-compat on many systems; installing plain zlib
              # alongside it would conflict, so add zlib only when absent
              if ! pacman -Qi zlib-ng-compat >/dev/null 2>&1; then
                  PKGS_BLD="$PKGS_BLD zlib"
              fi
              ;;
        apk)  PKGS_RT="curl gzip ipset iptables"
              PKGS_BLD="git make gcc musl-dev pkgconf libnetfilter_queue-dev libmnl-dev zlib-dev libcap-dev luajit-dev"
              ;;
        zypper) PKGS_RT="curl gzip ipset iptables"
              PKGS_BLD="git make gcc pkg-config libnetfilter_queue-devel libmnl-devel zlib-devel libcap-devel luajit-devel systemd-devel"
              ;;
        xbps) PKGS_RT="curl gzip ipset iptables"
              PKGS_BLD="git make gcc pkg-config libnetfilter_queue-devel libmnl-devel zlib-devel libcap-devel luajit-devel"
              ;;
        *)    PKGS_RT=""; PKGS_BLD="" ;;
    esac
}

pm_install(){
    local pkgs="$*"
    [ -n "${pkgs// }" ] || return 0
    case "$PM" in
        apt)   sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
               sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs ;;
        dnf)   sudo dnf -y --setopt=install_weak_deps=False install $pkgs ;;
        yum)   sudo yum -y install $pkgs ;;
        pacman) sudo pacman -S --noconfirm --needed $pkgs ;;
        apk)   sudo apk add --no-cache $pkgs ;;
        zypper) sudo zypper refresh >/dev/null 2>&1 || true
                sudo zypper --non-interactive install $pkgs ;;
        xbps)  sudo xbps-install -y $pkgs ;;
        *)     return 1 ;;
    esac
}

get_pkg_lists
pm_install "$PKGS_RT" || log_warn "Не удалось установить рантайм-зависимости. Проверьте вручную: curl, ipset, iptables/nftables"
pm_install "$PKGS_BLD" || log_warn "Не удалось установить зависимости сборки. Сборка может не пройти."
command -v cc gcc 2>/dev/null | grep -q . || log_err "Компилятор gcc/cc не найден"
command -v make >/dev/null 2>&1 || log_err "make не найден"

# ---------------------------------------------------------------------------
# Firewall backend auto-detection
# ---------------------------------------------------------------------------
detect_fwtype(){
    if command -v iptables >/dev/null 2>&1 && [ -x "$(command -v iptables)" ]; then
        echo "iptables"
    elif command -v nft >/dev/null 2>&1; then
        echo "nftables"
    else
        echo "iptables"
    fi
}
FWTYPE_UNIVERSAL=$(detect_fwtype)
log_ok "Тип файрвола: $FWTYPE_UNIVERSAL"
if [ "$FWTYPE_UNIVERSAL" = nftables ]; then
    pm_install nftables >/dev/null 2>&1 || true
else
    pm_install ip6tables >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Build zapret2 from official sources
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/bol-van/zapret2.git"
TMPDIR_UNI="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_UNI"' EXIT

log_ok "Клонирование официального репозитория zapret2"
git clone --depth=1 "$REPO_URL" "$TMPDIR_UNI/zapret2" || log_err "git clone не удался"

log_ok "Сборка из исходников (make -j$(nproc))"
BUILD_LOG="$TMPDIR_UNI/build.log"
if ! make -C "$TMPDIR_UNI/zapret2" -j"$(nproc)" >"$BUILD_LOG" 2>&1; then
    echo "--- последние строки лога сборки ---"
    tail -n 40 "$BUILD_LOG" 2>/dev/null
    log_err "Сборка не удалась. Установите dev-пакеты (Luajit2 обязателен) и повторите."
fi
[ -x "$TMPDIR_UNI/zapret2/nfq2/nfqws2" ] || log_err "nfqws2 не собран"
log_ok "nfqws2 собран (зависит от zapret-lib.lua / zapret-antidpi.lua / zapret-auto.lua)"

# ---------------------------------------------------------------------------
# Install to /opt/zapret2
# ---------------------------------------------------------------------------
sudo rm -rf /opt/zapret2
sudo cp -a "$TMPDIR_UNI/zapret2" /opt/zapret2
log_ok "/opt/zapret2 установлен (ZAPRET_BASE=/opt/zapret2)"

sudo mkdir -p /opt/zapret2/ipset /opt/zapret2/files

# service user (daemons drop privileges to it)
if ! id -u zapret2 >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin zapret2 2>/dev/null \
        || sudo useradd --system --no-create-home --shell /bin/false zapret2 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Config
# nfqws2 differs from nfqws1: strategies are Lua programs.
# Vars: NFQWS2_* instead of NFQWS_*, QNUM (default 300), MODE_FILTER.
# Helpers: --lua-init=@...lua, --lua-desync=... , --payload, --filter-l7,
#          ranges --in-range/--out-range instead of --dpi-desync-cutoff/start.
# ---------------------------------------------------------------------------
write_config(){ # $1=target file, $2=NFQWS2_OPT block
    local f="$1" opt="$2"
    sudo tee "$f" >/dev/null <<EOF
# this file is included from init scripts
# change values here

#TMPDIR=/opt/zapret2/tmp

# redefine user for zapret daemons
WS_USER=zapret2

# override firewall type : iptables,nftables,ipfw
FWTYPE=$FWTYPE_UNIVERSAL

SET_MAXELEM=522288
IPSET_OPT="hashsize 262144 maxelem \$SET_MAXELEM"

IP2NET_OPT4="--prefix-length=22-30 --v4-threshold=3/4"
IP2NET_OPT6="--prefix-length=56-64 --v6-threshold=5"

# options for auto hostlist (nfqws2 uses new knobs, old RETRANS/FAIL still exist)
AUTOHOSTLIST_INCOMING_MAXSEQ=4096
AUTOHOSTLIST_RETRANS_MAXSEQ=32768
AUTOHOSTLIST_RETRANS_RESET=1
AUTOHOSTLIST_RETRANS_THRESHOLD=3
AUTOHOSTLIST_FAIL_THRESHOLD=3
AUTOHOSTLIST_FAIL_TIME=60
AUTOHOSTLIST_UDP_IN=1
AUTOHOSTLIST_UDP_OUT=4
AUTOHOSTLIST_DEBUGLOG=0

MDIG_THREADS=30
MDIG_EAGAIN=10
MDIG_EAGAIN_DELAY=500

GZIP_LISTS=1

# mark bit used by nfqws2 to prevent loop
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000

NFQWS2_ENABLE=1
QNUM=300
# redirect outgoing traffic with connbytes limiter applied in both directions.
NFQWS2_PORTS_TCP=80,443
NFQWS2_PORTS_UDP=443
NFQWS2_TCP_PKT_OUT=20
NFQWS2_TCP_PKT_IN=10
NFQWS2_UDP_PKT_OUT=5
NFQWS2_UDP_PKT_IN=3
# use <HOSTLIST> and <HOSTLIST_NOAUTO> placeholders to engage standard hostlists
# and autohostlist in ipset dir. <HOSTLIST_NOAUTO> appends
# ipset/zapret-hosts-auto.txt as normal list.
# This rule is the current strategy (fake + multidisorder/multisplit).
NFQWS2_OPT="$opt"
# none,ipset,hostlist,autohostlist
MODE_FILTER=autohostlist

FLOWOFFLOAD=donttouch

INIT_APPLY_FW=1

# do not work with ipv4
#DISABLE_IPV4=1
# do not work with ipv6
DISABLE_IPV6=1

FILTER_TTL_EXPIRED_ICMP=1

# select which init script will be used to get ip or host list
# (get_user.sh get_antizapret.sh get_reestr.sh ...) . comment if not required
#GETLIST=
EOF
}

# --- preset strategies (Lua) written as ready-to-use switch profiles ---
OPT_DEFAULT="
--filter-tcp=80 --filter-l7=http <HOSTLIST> --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2 --new
--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld --new
--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6
"
OPT_SPLIT="
--filter-tcp=80 --filter-l7=http <HOSTLIST> --payload=http_req --lua-desync=multisplit:pos=method+2 --new
--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=multidisorder:pos=midsld --new
--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6
"
OPT_FAKE="
--filter-tcp=80 --filter-l7=http <HOSTLIST> --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --new
--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --new
--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6
"
OPT_RAW="
--filter-tcp=80,443 --filter-l7=http,tls <HOSTLIST> --lua-desync=send:ipfrag:ipfrag_pos_tcp=32 --lua-desync=drop --new
--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> --lua-desync=send:ipfrag:ipfrag_pos_udp=8 --lua-desync=drop
"

write_config /opt/zapret2/config "$OPT_DEFAULT"
log_ok "Конфиг /opt/zapret2/config записан (FWTYPE=$FWTYPE_UNIVERSAL)"

# ---------------------------------------------------------------------------
# Hostlists
# ---------------------------------------------------------------------------
sudo tee /opt/zapret2/ipset/zapret-hosts-user.txt >/dev/null <<'EOF'
youtube.com
googlevideo.com
ggpht.com
ytimg.com
yt.be
youtu.be
googleadservices.com
gvt1.com
youtube-nocookie.com
youtube-ui.l.google.com
youtubeembeddedplayer.googleapis.com
youtube.googleapis.com
youtubei.googleapis.com
jnn-pa.googleapis.com
yt-video-upload.l.google.com
wide-youtube.l.google.com
play.google.com
accounts.google.com
youtubekids.com
fonts.googleapis.com
googleads.g.doubleclick.net
news.google.com
instagram.com
www.instagram.com
cdninstagram.com
www.cdninstagram.com
facebook.com
www.facebook.com
fbcdn.net
www.fbcdn.net
fburl.com
fbsbx.com
twitter.com
twimg.com
t.co
x.com
rutor.info
rutor.is
nnmclub.to
rutracker.org
rutracker.cc
discord.com
discord.co
discord.app
discord.gg
discordapp.com
discordapp.net
discordcdn.com
discordstatus.com
discord.media
dis.gd
discord-attachments-uploads-prd.storage.googleapis.com
cloudflare-ech.com
cloudflare.com
1.1.1.1
amazon.com
amazonaws.com
ntc.party
torproject.org
meduza.io
te-st.org
EOF

sudo tee /opt/zapret2/ipset/zapret-hosts-user-exclude.txt >/dev/null <<'EOF'
# Файл исключений для zapret2
# Домены и IP-адреса, которые НЕ должны обрабатываться zapret2
# Формат: один домен/IP на строку
EOF

sudo chown -R zapret2:zapret2 /opt/zapret2/ipset 2>/dev/null || true

# ---------------------------------------------------------------------------
# systemd units (from the repo) + update timer
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    sudo cp /opt/zapret2/init.d/systemd/zapret2.service /etc/systemd/system/zapret2.service
    if [ -f /opt/zapret2/init.d/systemd/zapret2-list-update.service ]; then
        sudo cp /opt/zapret2/init.d/systemd/zapret2-list-update.service /etc/systemd/system/ 2>/dev/null || true
        sudo cp /opt/zapret2/init.d/systemd/zapret2-list-update.timer /etc/systemd/system/ 2>/dev/null || true
    fi
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl enable zapret2.service >/dev/null 2>&1 || true
    sudo systemctl restart zapret2.service >/dev/null 2>&1 || true
    sudo systemctl enable zapret2-list-update.timer >/dev/null 2>&1 || true
    sudo systemctl start zapret2-list-update.timer >/dev/null 2>&1 || true
else
    log_warn "systemd не найден. Запускайте вручную: sudo /opt/zapret2/init.d/sysv/zapret2 start"
    sudo /opt/zapret2/init.d/sysv/zapret2 start >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Install config-switch tool
# ---------------------------------------------------------------------------
# Switch tool expects to live in the project dir; copy it to /usr/local/bin.
# When run via `curl ... | sh` there is no local file, so fall back to the repo.
SWITCH_SRC="$(dirname "$(readlink -f "$0")")/zapret2switch.sh"
if [ ! -f "$SWITCH_SRC" ]; then
    log_warn "zapret2switch.sh не найден рядом со скриптом, скачиваю из репозитория"
    SWITCH_SRC="$TMPDIR_UNI/zapret2switch.sh"
    curl -fsSL "https://raw.githubusercontent.com/als-creator/autoinstall_zapret2/main/zapret2switch.sh" -o "$SWITCH_SRC" || SWITCH_SRC=""
fi
if [ -n "$SWITCH_SRC" ] && [ -f "$SWITCH_SRC" ]; then
    sudo install -m 0755 "$SWITCH_SRC" /usr/local/bin/zapret2switch
    # create first profile "default" from the freshly written config
    sudo zapret2switch save default >/dev/null 2>&1 || true
    log_ok "Утилита переключения конфигов установлена: zapret2switch (профиль 'default' сохранён)"

    # preinstall ready-made strategy profiles for easy switching (trial and error)
    PROFILES_DIR="/etc/zapret2/profiles"
    sudo mkdir -p "$PROFILES_DIR"
    write_config "$PROFILES_DIR/split/config" "$OPT_SPLIT"
    write_config "$PROFILES_DIR/fake/config" "$OPT_FAKE"
    write_config "$PROFILES_DIR/rawsend/config" "$OPT_RAW"
    write_config "$PROFILES_DIR/off/config" ""   # пустое правило = проверка без обработки
    for p in split fake rawsend off; do
        sudo rm -f "$PROFILES_DIR/$p/zapret-hosts-user.txt" \
                       "$PROFILES_DIR/$p/zapret-hosts-user-exclude.txt"
    done
    log_ok "Готовые профили стратегий: split, fake, rawsend, off (см. zapret2switch list)"
else
    log_warn "zapret2switch.sh недоступен — переключение конфигов не установлено"
fi

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
sleep 2
log_ok "Статус сервиса:"
sudo systemctl --no-pager --type=service status zapret2.service --lines=5 2>/dev/null | head -10 || true

echo
if pgrep -x nfqws2 >/dev/null 2>&1; then
    log_ok "Демон nfqws2 запущен"
else
    log_warn "nfqws2 не запущен — смотрите журнал: sudo journalctl -u zapret2.service -n 50"
fi

verify_fw(){
    case "$FWTYPE_UNIVERSAL" in
        iptables)
            if sudo iptables -t mangle -nL 2>/dev/null | grep -q NFQUEUE; then
                log_ok "Правила применены: правило NFQUEUE в mangle присутствует"
            else
                log_warn "Правило NFQUEUE не найдено. Проверьте: sudo iptables -t mangle -nL"
            fi
            ;;
        nftables)
            if sudo nft list table inet zapret2 >/dev/null 2>&1; then
                log_ok "Правила применены: таблица 'inet zapret2' в nftables присутствует"
            else
                log_warn "Таблица 'inet zapret2' не найдена. Проверьте: sudo nft list table inet zapret2"
            fi
            ;;
    esac
}
verify_fw

cat <<'EOF'

──────────────────────────────────────────────
  ZAPRET2 УСТАНОВЛЕН
──────────────────────────────────────────────

 Расположение (ZAPRET_BASE):  /opt/zapret2
 Конфиг:                     /opt/zapret2/config   (переменные NFQWS2_*)
 Демон:                      /opt/zapret2/nfq2/nfqws2
 Стратегии Lua:              /opt/zapret2/lua/zapret-lib.lua
                             /opt/zapret2/lua/zapret-antidpi.lua

──────────────────────────────────────────────
 СПИСКИ ДОМЕНОВ

   Обрабатывать:     /opt/zapret2/ipset/zapret-hosts-user.txt
   Исключения:       /opt/zapret2/ipset/zapret-hosts-user-exclude.txt

──────────────────────────────────────────────
 УПРАВЛЕНИЕ СЕРВИСОМ

   sudo systemctl start|stop|restart zapret2.service
   sudo systemctl status zapret2.service
   sudo journalctl -u zapret2.service -f
   sudo systemctl enable|disable zapret2.service

──────────────────────────────────────────────
 ОБНОВЛЕНИЕ СПИСКОВ ДОМЕНОВ

   авто:   zapret2-list-update.timer (каждый час)
   вручн:  sudo /opt/zapret2/init.d/sysv/zapret2 reload-ifsets

──────────────────────────────────────────────
 ПЕРЕКЛЮЧЕНИЕ НАБОРОВ КОНФИГОВ

   sudo zapret2switch list
   sudo zapret2switch apply <набор>
   sudo zapret2switch save  <набор>    # сохранить текущий как набор
   Готовые профили: default split fake rawsend off
   Профили лежат в: /etc/zapret2/profiles/

──────────────────────────────────────────────
 ПОИСК ПРОБЛЕМ

   sudo journalctl -u zapret2.service -n 50
   sudo /opt/zapret2/blockcheck2.sh     # подбор правила под провайдера
   Мануал: https://github.com/bol-van/zapret2/blob/master/docs/manual.md

──────────────────────────────────────────────
 УДАЛЕНИЕ

   sudo systemctl disable --now zapret2.service zapret2-list-update.timer
   sudo rm /etc/systemd/system/zapret2.service /etc/systemd/system/zapret2-list-update.*
   sudo systemctl daemon-reload
   sudo rm -rf /opt/zapret2 /etc/zapret2
   sudo rm -f /usr/local/bin/zapret2switch
EOF

exit 0