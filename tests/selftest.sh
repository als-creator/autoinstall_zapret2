#!/bin/sh
# Самопроверка установщика zapret.
#
# Проверяет:
#   1) --remove действительно снимает всё: каталог (вместе со списками и .bak),
#      юниты и остатки конфигов;
#   2) список доменов перезаписывается, а прежний сохраняется в .bak (по коду);
#   3) --keep-lists распознаётся;
#   4) синтаксис скрипта.
#
# Ничего системного не трогает: sudo/systemctl/iptables/nft подменяются
# заглушками, пути перенаправляются в build/selftest репозитория.
#
# Запуск:  sh tests/selftest.sh [путь-к-установщику]

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${1:-}" ]; then
    SCRIPT=$1
else
    SCRIPT=""
    for cand in "$HERE"/autoinstall_*.sh; do
        [ -f "$cand" ] && { SCRIPT=$cand; break; }
    done
fi
[ -n "$SCRIPT" ] && [ -f "$SCRIPT" ] || { echo "не найден установщик: ${SCRIPT:-в $HERE}"; exit 1; }

# Каталог установки: /opt/zapret или /opt/zapret2
ZDIR=$(grep -oE '/opt/zapret[0-9]*' "$SCRIPT" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
[ -n "$ZDIR" ] || { echo "не удалось определить каталог установки"; exit 1; }

WORK="$HERE/build/selftest"
ROOT="$WORK/root"
BIN="$WORK/bin"
rm -rf "$WORK"
mkdir -p "$BIN" "$ROOT$ZDIR/ipset" "$ROOT/etc/systemd/system" "$ROOT/etc/zapret"

cat > "$BIN/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
for t in systemctl iptables iptables-save nft pgrep; do
    printf '#!/bin/sh\nexit 0\n' > "$BIN/$t"
done
chmod +x "$BIN"/*

sed \
    -e "s|$ZDIR|$ROOT$ZDIR|g" \
    -e "s|/etc/systemd/system|$ROOT/etc/systemd/system|g" \
    -e "s|/etc/zapret2|$ROOT/etc/zapret2|g" \
    -e "s|/etc/zapret|$ROOT/etc/zapret|g" \
    "$SCRIPT" > "$WORK/under-test.sh"

pass=0; fail=0
ok(){  printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
check(){ if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

echo "=== Самопроверка: $(basename "$SCRIPT") (каталог $ZDIR) ==="

# --- 0. синтаксис ---------------------------------------------------------
echo "0) синтаксис"
bash -n "$SCRIPT" 2>"$WORK/syntax.err"
check "bash -n без ошибок" "$?"

# --- 1. список перезаписывается и бэкапится (по коду) ---------------------
echo "1) перезапись списка с бэкапом"
grep -q 'zapret-hosts-user.txt.bak-$(date' "$SCRIPT"
check "в скрипте есть бэкап списка (.bak-<дата>)" "$?"
grep -q -- '--keep-lists' "$SCRIPT"
check "--keep-lists распознаётся" "$?"
grep -q 'KEEP_LISTS" != "yes"' "$SCRIPT"
check "при --keep-lists список не перезаписывается" "$?"
grep -q -- '--block-quic' "$SCRIPT"
check "--block-quic распознаётся" "$?"

# --- 2. удаление ----------------------------------------------------------
echo "2) --remove: удаление"
echo "СТАРЫЙ-СПИСОК" > "$ROOT$ZDIR/ipset/zapret-hosts-user.txt"
touch "$ROOT/etc/systemd/system/zapret.service" "$ROOT/etc/zapret/old.conf" \
      "$ROOT/etc/systemd/system/zapret-quic.service"
PATH="$BIN:$PATH" sh "$WORK/under-test.sh" --remove >"$WORK/remove.log" 2>&1
check "--remove завершился успешно" "$?"
check "каталог $ZDIR удалён целиком (со списками и .bak)" "$([ ! -d "$ROOT$ZDIR" ] && echo 0 || echo 1)"
check "юнит zapret удалён" "$([ ! -e "$ROOT/etc/systemd/system/zapret.service" ] && echo 0 || echo 1)"
check "юнит zapret-quic удалён" "$([ ! -e "$ROOT/etc/systemd/system/zapret-quic.service" ] && echo 0 || echo 1)"
grep -q 'ZAPRET_QUIC' "$SCRIPT"
check "правило ZAPRET_QUIC снимается при --remove" "$?"
check "старый конфиг /etc/zapret удалён" "$([ ! -d "$ROOT/etc/zapret" ] && echo 0 || echo 1)"

echo
echo "Итог: PASS=$pass FAIL=$fail"
echo "Логи: $WORK/*.log"
[ "$fail" -eq 0 ]
