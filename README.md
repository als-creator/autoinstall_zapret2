# AutoInstall Zapret2

## Описание

Скрипт автоматизирует установку и настройку **zapret2** — основной, активно
развиваемой ветки zapret от [bol-van](https://github.com/bol-van/zapret2).

В отличие от v1 (EOL), zapret2 **собирается из исходников** под вашу систему
(никаких чужих бинарников) и использует **Lua-стратегии** вместо зашитых в
C-код опций `--dpi-desync=...`. Скрипт сам определяет пакетный менеджер,
ставит зависимости (рантайм + сборка), определяет тип файрвола
(iptables/nftables), пишет правило для `nfqws2`, списки доменов и exceptions,
создаёт systemd-сервис с автозагрузкой и утилиту переключения конфигов.

Устанавливается в `/opt/zapret2` — отдельно от zapret v1 (`/opt/zapret`),
обе версии могут сосуществовать на одной системе.

## Автоустановка

Запустите скрипт по ссылке:

```bash
curl -fsSL https://raw.githubusercontent.com/als-creator/autoinstall_zapret2/main/autoinstall_zapret2.sh | sh
```

Скрипт попросит пароль для выполнения команд через sudo.

Или скачайте проект и запустите вручную:

```bash
git clone https://github.com/als-creator/autoinstall_zapret2
cd autoinstall_zapret2
./autoinstall_zapret2.sh
```

## Управление сервисом

```bash
sudo systemctl start|stop|restart zapret2.service
sudo systemctl status zapret2.service
sudo journalctl -u zapret2.service -f
```

Обновление списков (вручную, помимо таймера):

```bash
sudo /opt/zapret2/init.d/sysv/zapret2 reload-ifsets
```

Минимальный ручной тест:

```bash
curl -v --max-time 10 https://rutracker.org 2>&1 | grep -E 'HTTP/|Connected to'
```

## Проверка после установки

```bash
sudo systemctl status zapret2.service --no-pager --lines=10
sudo systemctl list-timers | grep zapret2
```

## Удаление zapret2

Если zapret2 больше не требуется, выполните одной командой:

```bash
su -c '
  if systemctl list-unit-files | grep -q "zapret2.service"; then
    systemctl disable --now zapret2.service
    systemctl disable --now zapret2-list-update.timer 2>/dev/null
    rm /etc/systemd/system/zapret2.service /etc/systemd/system/zapret2-list-update.*
    systemctl daemon-reload
  fi
  rm -rf /opt/zapret2 /etc/zapret2
  rm -f /usr/local/bin/zapret2switch
'
```

То же самое в несколько команд:

```bash
sudo systemctl disable --now zapret2.service
sudo systemctl disable --now zapret2-list-update.timer 2>/dev/null
sudo rm /etc/systemd/system/zapret2.service /etc/systemd/system/zapret2-list-update.timer
sudo systemctl daemon-reload
sudo rm -rf /opt/zapret2 /etc/zapret2 /usr/local/bin/zapret2switch
```

---

## Дальше — для тех, кто хочет разобраться глубже

### Что делает скрипт

1. Проверяет sudo, git, определяет пакетный менеджер (apt, dnf, yum, zypper, pacman, apk, xbps)
2. Ставит рантайм-зависимости: curl, gzip, ipset, iptables/nftables
3. Ставит зависимости сборки: gcc, make, pkg-config, dev-заголовки (netfilter_queue, mnl, zlib, libcap, luajit)
4. Клонирует официальный репозиторий bol-van/zapret2
5. Собирает из исходников под вашу систему
6. Копирует zapret2 в /opt/zapret2
7. Определяет и прописывает FWTYPE (iptables или nftables)
8. Пишет конфиг с NFQWS2-правилом (Lua-стратегии) и списки хостов/исключений
9. Создаёт systemd unit `zapret2.service` и таймер обновления списков
10. Устанавливает утилиту `zapret2switch` в /usr/local/bin
11. Запускает сервис и проверяет, что демон работает и правило применилось

### Чем отличаются версии zapret (v1 и v2)

**zapret (v1, EOL)** — старая ветка. Автор перевёл её в режим End-Of-Life:
новых функций не будет, только исправления ошибок. Основной компонент `nfqws`
подключает файрвола в NFQUEUE и содержит **стратегии обхода DPI, зашитые в C-код**
(опции `--dpi-desync=...`, `--dpi-desync-fooling=...`, `--dpi-desync-fake-tls=...`
и т.д.). Для http-трафика есть и второй демон `tpws`.

**zapret2 (v2)** — дальнейшее развитие. `nfqws2` сохраняет всё ядро (распознавание
протоколов, реассемблинг, дешифровку TLS/QUIC, хостлисты, ipsets, профили), но
**лишается готового «дурения»**: теперь стратегии — это **программы на Lua**,
а не опции командной строки. Это сделано намеренно: методы обхода DPI меняются
довольно быстро, и переписывать C-код каждый раз слишком тяжело. Пользователь
(или комьюнити) может написать свою стратегию на Lua, не трогая C.

| Аспект | zapret v1 (EOL) | zapret2 (актуальный) |
|---|---|---|
| Статус | EOL, только багфиксы | активная разработка |
| Демоны | `nfqws` (NFQUEUE) + `tpws` | **только `nfqws2`** (`tpws` убран) |
| Стратегии обхода | встроены в C (`--dpi-desync=*`) | Lua-скрипты (`--lua-desync=*`) |
| Файлы стратегий | нет | `/opt/zapret2/lua/zapret-lib.lua`, `zapret-antidpi.lua`, `zapret-auto.lua` |
| Кастомные фейки | `--dpi-desync-fake-tls/...` | «блобы» `blob=fake_default_tls` и т.п., любая hex-строка или файл |
| Пределы пакетов | `--dpi-desync-cutoff/start` | диапазоны `--in-range`, `--out-range` (счётчики n/d/b/s) |
| Фильтрация протоколов | `--filter-tcp/udp` | + новый `--filter-l7` (http/tls/quic/...) |
| Фильтрация содержимого | часто через `--dpi-desync-any-protocol` | новый `--payload` (тип пейлоада, например `tls_client_hello`) |
| any-protocol | нужно включать | **режим по умолчанию** |
| Сегментация TCP | фиксированная | автоматическая с учётом MSS (`rawsend_dissect_segmented`) |
| IP фрагментация | `--dpi-desync=ipfrag2` | `--lua-desync=send:ipfrag` + `--lua-desync=drop` |
| TTL для IPv6 | автоматически | нужно явно: `ip6_ttl`, нет авто-ttl |
| Поддержка серверного режима | нет | `--server` (адаптация адресов для ipset/фильтров) |
| Переменные конфига | `NFQWS_ENABLE`, `NFQWS_OPT`, ... | `NFQWS2_ENABLE`, `NFQWS2_OPT`, `QNUM`, ... |
| Базовый каталог | `/opt/zapret` | `/opt/zapret2` |

Пример портирования правила (из официального README zapret2):

```bash
# zapret v1
nfqws --qnum=200 --filter-tcp=443 --filter-l7=tls --hostlist=list.txt \
  --dpi-desync=fake,split --dpi-desync-split-pos=midsld --dpi-desync-repeats=6 \
  --dpi-desync-fooling=badseq --dpi-desync-fake-tls=...

# zapret2
nfqws2 --qnum=300 --lua-init=@lua/zapret-lib.lua --lua-init=@lua/zapret-antidpi.lua \
  --filter-tcp=443 --filter-l7=tls --hostlist=list.txt \
  --payload=tls_client_hello \
  --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 \
  --lua-desync=multidisorder:pos=midsld
```

Подробнее — в [официальном мануале](https://github.com/bol-van/zapret2/blob/master/docs/manual.md).

## Где лежат конфиги и чем отличаются пути от zapret v1

Здесь установщик использует те же соглашения, что и оригинальный zapret2:
`ZAPRET_BASE=/opt/zapret2`, конфиг — `/opt/zapret2/config`.

| Что | zapret v1 (EOL) | zapret2 |
|---|---|---|
| Основной конфиг | `/opt/zapret/config` | `/opt/zapret2/config` |
| Обработка IP-списков | `/opt/zapret/ipset/` | `/opt/zapret2/ipset/` |
| Список доменов (то, что обходить) | `.../ipset/zapret-hosts-user.txt` | `/opt/zapret2/ipset/zapret-hosts-user.txt` |
| Исключения (НЕ обрабатывать) | `.../ipset/zapret-hosts-user-exclude.txt` | `/opt/zapret2/ipset/zapret-hosts-user-exclude.txt` |
| Бинарь демона | `/opt/zapret/nfq/nfqws` | `/opt/zapret2/nfq2/nfqws2` |
| Логика запуска | `/opt/zapret/init.d/sysv/zapret` | `/opt/zapret2/init.d/sysv/zapret2` |
| Стратегии Lua | — | `/opt/zapret2/lua/*.lua` |
| systemd unit | `zapret.service` | `zapret2.service` |
| Таймер обновления списков | (по желанию) | `zapret2-list-update.timer` |
| Пользователь для демона | `zapret` / `tpws` | `zapret2` (`WS_USER=zapret2`) |

### Переменные конфига: v1 → v2

| zapret v1 | zapret2 | Примечание |
|---|---|---|
| `NFQWS_ENABLE=1` | `NFQWS2_ENABLE=1` | включая демон |
| `NFQWS_PORTS_TCP=80,443` | `NFQWS2_PORTS_TCP=80,443` | порты для перенаправления |
| `NFQWS_PORTS_UDP=443` | `NFQWS2_PORTS_UDP=443` | UDP (quic/discord и т.п.) |
| `NFQWS_TCP_PKT_OUT`, `...PKT_IN` | `NFQWS2_TCP_PKT_OUT`, `NFQWS2_TCP_PKT_IN` | сколько первых пакетов соединения отправлять в очередь |
| `NFQWS_UDP_PKT_OUT`, `...PKT_IN` | `NFQWS2_UDP_PKT_OUT`, `NFQWS2_UDP_PKT_IN` | то же для UDP |
| `NFQWS_OPT="..."` | `NFQWS2_OPT="..."` | главный параметр — правило со стратегиями |
| — | `QNUM=300` | номер NFQUEUE (в systemd-сервисе v1 был 200) |
| `AUTOHOSTLIST_RETRANS_THRESHOLD`, `...FAIL_THRESHOLD`, `...FAIL_TIME` | сохранились | параметры автолиста |
| — | `AUTOHOSTLIST_INCOMING_MAXSEQ`, `AUTOHOSTLIST_RETRANS_MAXSEQ`, `AUTOHOSTLIST_UDP_IN`, `AUTOHOSTLIST_UDP_OUT` | новые настройки автолиста v2 |
| `MODE_FILTER`, `FWTYPE`, `DESYNC_MARK`, `DISABLE_IPV6`, `INIT_APPLY_FW` | идентичны | общие переменные |
| `WS_USER=zapret` | `WS_USER=zapret2` | привилегий-пользователь демона |

Установщиком по умолчанию записывается конфиг с правилом, эквивалентным
классическому nfqws1-правилу (http/tls/quic через `fake` + `multisplit`/`multidisorder`):

```ini
NFQWS2_OPT="
--filter-tcp=80 --filter-l7=http <HOSTLIST> --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2 --new
--filter-tcp=443 --filter-l7=tls <HOSTLIST> --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld --new
--filter-udp=443 --filter-l7=quic <HOSTLIST_NOAUTO> --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6
"
MODE_FILTER=autohostlist
```

`<HOSTLIST>` и `<HOSTLIST_NOAUTO>` — плейсхолдеры: init-скрипты подставляют в них
реальные файлы списков из `/opt/zapret2/ipset/` (как в конфиге zapret v1).

## Как менять руками

Все изменения требуют перезапуска сервиса.

```bash
# 1. Основной конфиг
sudo nano /opt/zapret2/config

# 2. Список доменов (то, что должно работать вопреки DPI)
sudo nano /opt/zapret2/ipset/zapret-hosts-user.txt

# 3. Исключения (банки, локальная сеть, важные госсайты — НЕ трогать)
sudo nano /opt/zapret2/ipset/zapret-hosts-user-exclude.txt

# 4. Перезапуск
sudo systemctl restart zapret2.service
```

Если меняли только списки — демон можно не перезапускать:

```bash
sudo /opt/zapret2/init.d/sysv/zapret2 reload-ifsets
```

Подобрать правило под конкретного провайдера можно скриптом из самого zapret2:

```bash
sudo /opt/zapret2/blockcheck2.sh
```

## Готовые конфиги и где их брать

- **Официальный репозиторий и мануал** — https://github.com/bol-van/zapret2
  (раздел `docs/manual.md`, там же примеры портирования старых правил на Lua).
- **Набор конфигураций `zapret.cfgs`** —
  https://github.com/Snowy-Fluffy/zapret.cfgs/tree/main/configurations —
  готовые правила под разных провайдеров/модемы. Это конфиги **для zapret v1**,
  но опции из них отлично переносятся в v2 (см. таблицу портирования выше).
- **Форум `ntc.party`** — https://ntc.party — обсуждение zapret, разбор новых
  блокировок, готовые параметры сообществом.
- **Обсуждения на rutracker / 4pda** — там периодически публикуют актуальные
  наборы стратегий для открытых сайтов.

Любой найденный готовый конфиг удобнее всего сохранить как **набор** и
переключаться между ними (см. ниже), не боясь что-то сломать.

## Переключение между наборами конфигов

Установщик кладёт утилиту `zapret2switch` в `/usr/local/bin`. Профили живут в
`/etc/zapret2/profiles/<имя>/` и могут содержать три файла (любые из них
опциональны):

```
/etc/zapret2/profiles/<имя>/
├── config                        # копия /opt/zapret2/config
├── zapret-hosts-user.txt         # списки доменов
└── zapret-hosts-user-exclude.txt # исключения
```

Команды (все — через sudo):

```bash
# список наборов и активный
sudo zapret2switch list

# применить набор (копирует файлы в /opt/zapret2 и перезапускает zapret2)
sudo zapret2switch apply имя-набора
# синоним:
sudo zapret2switch use имя-набора

# сохранить текущие конфиги как новый набор (снапшот)
sudo zapret2switch save имя-набора

# показать, что внутри набора
sudo zapret2switch show имя-набора

# показать активный набор
sudo zapret2switch current

# удалить набор (активный удалять нельзя)
sudo zapret2switch remove имя-набора

# просто перезапустить zapret2
sudo zapret2switch reload
```

Установщик сразу создаёт несколько **готовых профилей стратегий**
(перебираются одной командой — меняется только `NFQWS2_OPT`, списки и
сервис общие):

```bash
sudo zapret2switch apply split    # только дробление/перестановка сегментов
sudo zapret2switch apply fake     # только поддельные пакеты (без перестановки)
sudo zapret2switch apply rawsend  # IP-фрагментация (send:ipfrag) + drop
sudo zapret2switch apply off      # пустое правило — проверка «без обработки»
sudo zapret2switch apply default  # вернуться к базовому
```

Порядок перебора при подборе под провайдера, как правило, такой:
`default` → `split` → `fake` → `rawsend` → `off` (для сравнения с «ничего не
делали»). После `apply` сервис перезапускается автоматически, остаётся только
проверить сайт:

```bash
curl -v --max-time 10 https://rutracker.org 2>&1 | grep -E 'HTTP/|Connected to'
```

#### В чём разница между готовыми профилями

Один и тот же трафик (HTTP/TLS/QUIC по портам 80/443), но nfqws2 «прячет»
пакеты от DPI разными техниками — профили меняют способ обработки.

| Профиль | Что делает с пакетом | Когда помогает |
|---|---|---|
| **default** | Три приёма сразу: фейковый первый пакет (вроде TLS/HTTP/QUIC приветствия) + **дробление и перестановка сегментов**. Самый «агрессивный». | Универсальный старт, большинство провайдеров |
| **split** | Только **дробление** и **перестановка сегментов** (multisplit/multidisorder), без фейков. | Когда DPI ловит TLS ClientHello по содержимому, а фейки дают сбой/замедление |
| **fake** | Только **фейковые пакеты**, порядок и дробление не меняются. | Когда DPI глушит именно по «паттерну» первого пакета, а десинхрон мешает |
| **rawsend** | **IP-фрагментация**: пакет режется на IP-фрагменты (`send:ipfrag:pos_tcp=32` / `pos_udp=8`) + исходный **drop**. | Для агрессивного DPI, который собирает TLS/QUIC из кусков в обход TCP-сегментации |
| **off** | Пустое правило — демон пропускает пакеты без изменений. | Контроль: убедиться, что «торможение» даёт именно zapret, а не сеть |

**Механика коротко:**

- **fake** — nfqws2 отсылает поддельный пакет (TLS-hello с мусором), чтобы DPI
  начал разбирать его, а настоящий первый пакет проходит незамеченным.
  В конфиге — `--lua-desync=fake:blob=fake_default_tls/...`.
- **split / multidisorder** — TCP-данные рвутся на куски или переставляются,
  чтобы DPI не «собрал» цельный ClientHello.
  В конфиге — `--lua-desync=multisplit:pos=...` / `--lua-desync=multidisorder:pos=...`.
- **rawsend** — физическая фрагментация на уровне IP (аналог `ipfrag2` из v1)
  плюс принудительный `drop` исходного пакета — против DPI, который прозрачно
  реассемблит TCP. В конфиге — `--lua-desync=send:ipfrag:... --lua-desync=drop`.

Подробности — в [manual.md](https://github.com/bol-van/zapret2/blob/master/docs/manual.md),
разделы про `fake`, `multisplit`/`multidisorder` и `send:ipfrag`.

Пример рабочего сценария:

```bash
sudo zapret2switch save базовый          # сохраняем то, что поставил установщик
sudo zapret2switch save провайдер-х     # ещё один снапшот
# ...экспериментируете с /opt/zapret2/config ...
sudo zapret2switch apply базовый        # вернулись к базовому
sudo zapret2switch apply провайдер-х    # снова висели набор 'провайдер-х'
```

Также можно клонировать/распаковывать чужие конфиги прямо в
`/etc/zapret2/profiles/<имя>/` (следя за именами файлов) и просто
`apply` их.

## Проверка зависимостей

```bash
sudo -v                                   # наличие sudo
git --version                             # наличие git (для клонирования/сборки)
command -v cc gcc                         # наличие компилятора
command -v make                           # наличие make
command -v pkg-config                     # наличие pkg-config
```

## Решение проблем

Если сервис не запускается, смотрите журнал:

```bash
sudo journalctl -u zapret2.service -n 50
```

Проверка, что демон и файрвол реально работают:

```bash
pgrep -x nfqws2                           # демон должен быть запущен
sudo iptables -t mangle -nL | grep NFQUEUE        # если FWTYPE=iptables
sudo nft list table inet zapret2          # если FWTYPE=nftables
```

Если демон запущен, но сайты не открываются, подберите правило под своего
провайдера (интерактивный тест из самого zapret2):

```bash
sudo /opt/zapret2/blockcheck2.sh
```

Готовые варианты правил можно взять в
[zapret.cfgs](https://github.com/Snowy-Fluffy/zapret.cfgs/tree/main/configurations)
(это конфиги для zapret v1, но опции переносятся в v2 — см. таблицу портирования)
и применить как набор через `zapret2switch`.

## Лицензия

Программный код zapret2 и конфиги принадлежат автору bol-van и распространяются
под его лицензией (см. `LICENSE` в https://github.com/bol-van/zapret2).
Этот проект — лишь вспомогательный установщик/конфигуратор.