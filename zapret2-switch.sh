#!/bin/bash
#
# zapret2-switch — переключение между наборами конфигов zapret2.
#
# Набор конфигов (профиль) — это каталог в /etc/zapret2/profiles/<имя>/,
# который может содержать:
#   config                       — основной конфиг /opt/zapret2/config
#   zapret-hosts-user.txt        — список доменов для обхода
#   zapret-hosts-user-exclude.txt — список исключений
#
# Любой файл профиля опционален: отсутствующие файлы не трогаются.
#
# Команды:
#   zapret2-switch list                — показать наборы и активный
#   zapret2-switch show [имя]           — показать содержимое набора
#   zapret2-switch current              — имя текущего активного набора
#   zapret2-switch apply <имя>          — применить набор и перезапустить zapret2
#   zapret2-switch use <имя>            — то же, что apply
#   zapret2-switch save <имя>           — сохранить текущие конфиги как набор
#   zapret2-switch remove <имя>         — удалить набор (не активный)
#   zapret2-switch reload               — просто перезапустить службу zapret2
#   zapret2-switch help                 — справка
#
set -uo pipefail

ZAPRET_BASE=${ZAPRET_BASE:-/opt/zapret2}
PROFILES_DIR=${PROFILES_DIR:-/etc/zapret2/profiles}
CONFIG_FILE="$ZAPRET_BASE/config"
IPSET_DIR="$ZAPRET_BASE/ipset"
ACTIVE_FILE="$PROFILES_DIR/.active"
SERVICE_USER=${ZAPRET2_SERVICE_USER:-zapret2}
SERVICE="zapret2.service"

log_ok(){ echo "[OK] $*"; }
log_err(){ echo "[ERROR] $*" >&2; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] || log_err "Запускайте с sudo: sudo zapret2-switch ..."
[ -d "$ZAPRET_BASE" ] || log_err "zapret2 не установлен ($ZAPRET_BASE отсутствует)"
command -v sudo >/dev/null 2>&1 || true

profile_exists(){ [ -d "$PROFILES_DIR/$1" ]; }

get_active(){
    if [ -f "$ACTIVE_FILE" ] && [ -d "$PROFILES_DIR/$(cat "$ACTIVE_FILE")" ]; then
        cat "$ACTIVE_FILE"
    else
        echo "default"
    fi
}

set_active(){ echo "$1" >"$ACTIVE_FILE"; }

restart_service(){
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$SERVICE"
    else
        "$ZAPRET_BASE/init.d/sysv/zapret2" restart
    fi
}

cmd_list(){
    local active active_profile
    active_profile=$(get_active)
    echo "Каталог наборов: $PROFILES_DIR"
    echo
    [ -d "$PROFILES_DIR" ] || { echo "Наборов пока нет (создайте командой save)."; return 0; }
    for dir in "$PROFILES_DIR"/*/; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        if [ "$name" = "$active_profile" ]; then
            echo "  * $name   <- активный"
        else
            echo "    $name"
        fi
    done
}

cmd_show(){
    local name="${1:-$(get_active)}"
    if ! profile_exists "$name"; then log_err "Набор '$name' не найден"; fi
    echo "Набор: $name ($PROFILES_DIR/$name)"
    echo " - config                      : $([ -f "$PROFILES_DIR/$name/config" ] && echo "есть" || echo "-")"
    echo " - zapret-hosts-user.txt       : $([ -f "$PROFILES_DIR/$name/zapret-hosts-user.txt" ] && echo "есть" || echo "-")"
    echo " - zapret-hosts-user-exclude.txt: $([ -f "$PROFILES_DIR/$name/zapret-hosts-user-exclude.txt" ] && echo "есть" || echo "-")"
    echo
    if [ -f "$PROFILES_DIR/$name/config" ]; then
        echo "--- начало config ---"
        grep -vE '^\s*(#|$)' "$PROFILES_DIR/$name/config" | sed -n '1,40p'
        echo "--- конец config ---"
    fi
}

cmd_apply(){
    local name="$1"
    profile_exists "$name" || log_err "Набор '$name' не найден (см. 'zapret2-switch list')"
    local changed=0

    if [ -f "$PROFILES_DIR/$name/config" ]; then
        cp "$PROFILES_DIR/$name/config" "$CONFIG_FILE"
        chown root:root "$CONFIG_FILE" 2>/dev/null
        changed=1
    fi

    if [ -d "$IPSET_DIR" ]; then
        for f in zapret-hosts-user.txt zapret-hosts-user-exclude.txt; do
            if [ -f "$PROFILES_DIR/$name/$f" ]; then
                cp "$PROFILES_DIR/$name/$f" "$IPSET_DIR/$f"
                chown "$SERVICE_USER":"$SERVICE_USER" "$IPSET_DIR/$f" 2>/dev/null
                chmod 664 "$IPSET_DIR/$f" 2>/dev/null
                changed=1
            fi
        done
    fi

    set_active "$name"
    if [ "$changed" = 1 ]; then
        restart_service && log_ok "Набор '$name' применён, служба перезапущена." \
            || log_err "Службу не удалось перезапустить, смотрите журнал."
    else
        log_ok "Набор '$name' пуст (файлов не было), конфиги не изменены."
    fi
}

cmd_save(){
    local name="$1"
    [ -n "$name" ] || log_err "Укажите имя набора: zapret2-switch save <имя>"
    mkdir -p "$PROFILES_DIR/$name"
    local changed=0

    [ -f "$CONFIG_FILE" ] && { cp "$CONFIG_FILE" "$PROFILES_DIR/$name/config"; changed=1; }
    for f in zapret-hosts-user.txt zapret-hosts-user-exclude.txt; do
        [ -f "$IPSET_DIR/$f" ] && { cp "$IPSET_DIR/$f" "$PROFILES_DIR/$name/$f"; changed=1; }
    done

    set_active "$name"
    if [ "$changed" = 1 ]; then
        log_ok "Текущие конфиги сохранены как набор '$name'."
    else
        log_warn "Сохранить оказалось нечего — $CONFIG_FILE отсутствует?"
    fi
}

cmd_remove(){
    local name="$1"
    profile_exists "$name" || log_err "Набор '$name' не найден"
    [ "$name" != "$(get_active)" ] || log_err "Нельзя удалить активный набор (сначала примените другой)"
    rm -rf "$PROFILES_DIR/$name"
    log_ok "Набор '$name' удалён."
}

cmd_reload(){
    restart_service && log_ok "Служба перезапущена." || log_err "Перезапуск не удался."
}

usage(){ sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-help}"
case "$cmd" in
    list|ls)     cmd_list ;;
    show|cat)    cmd_show "${2:-}" ;;
    current)     echo "$(get_active)" ;;
    apply|use)   [ -n "${2:-}" ] || log_err "Укажите имя набора: zapret2-switch apply <имя>"
                 cmd_apply "$2" ;;
    save)        [ -n "${2:-}" ] || log_err "Укажите имя набора: zapret2-switch save <имя>"
                 cmd_save "$2" ;;
    remove|rm)   [ -n "${2:-}" ] || log_err "Укажите имя набора: zapret2-switch remove <имя>"
                 cmd_remove "$2" ;;
    reload)      cmd_reload ;;
    help|-h|--help) usage ;;
    *) usage ;;
esac

exit 0