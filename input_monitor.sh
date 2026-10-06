#!/usr/bin/env bash
# =============================================================================
# input_monitor.sh — подключённые устройства ввода из /proc/bus/input
#
# Использование:
#   ./input_monitor.sh          — показать устройства и записать новые в лог
#   ./input_monitor.sh -q       — «тихий» режим для cron: только запись в лог
#   ./input_monitor.sh -d [N]   — фоновый режим: при старте показать устройства,
#                                 далее каждые N сек (по умолчанию 5) проверять
#                                 и сигнализировать о новых подключениях
#   Запуск в фоне:  nohup ./input_monitor.sh -d 5 > /dev/null 2>&1 &
# =============================================================================

set -u

INPUT_DIR="${INPUT_DIR:-/proc/bus/input}"
DEVICES_FILE="$INPUT_DIR/devices"

MODE="normal"; INTERVAL=5
case "${1:-}" in
    -q) MODE="quiet" ;;
    -d) MODE="daemon"; INTERVAL="${2:-5}" ;;
esac

LOG_DIR="${LOG_DIR:-/var/log/input_monitor}"
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
    LOG_DIR="$HOME/.local/state/input_monitor"
    mkdir -p "$LOG_DIR"
fi
LOG_FILE="$LOG_DIR/input_monitor.log"
STATE_FILE="$LOG_DIR/known_devices.state"

if [[ ! -r $DEVICES_FILE ]]; then
    echo "Ошибка: нет доступа к $DEVICES_FILE" >&2
    exit 1
fi

# =============================================================================
# 2.1. Просмотр содержимого /proc/bus/input/
# =============================================================================
show_input_dir() {
    echo "Содержимое $INPUT_DIR:"
    local f
    for f in "$INPUT_DIR"/*; do
        echo "  ${f##*/}"
    done
    echo
}

# =============================================================================
# 2.2. Разбор /proc/bus/input/devices по столбцам (в цикле)
#
# Файл состоит из блоков, разделённых пустой строкой:
#   I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
#   N: Name="AT Translated Set 2 keyboard"
#   P: Phys=isa0060/serio0/input0
#   S: Sysfs=/devices/platform/i8042/serio0/input/input0
#   H: Handlers=sysrq kbd event0
#   B: ...
# =============================================================================
parse_devices() {
    DEV_BUS=(); DEV_VENDOR=(); DEV_PRODUCT=(); DEV_VERSION=()
    DEV_NAME=(); DEV_PHYS=(); DEV_SYSFS=(); DEV_HANDLERS=()

    local line kv
    local bus="" vendor="" product="" version="" name="" phys="" sysfs="" handlers=""

    flush() {   # сохранить накопленный блок как одно устройство
        if [[ -n $name || -n $sysfs ]]; then
            DEV_BUS+=("$bus");   DEV_VENDOR+=("$vendor")
            DEV_PRODUCT+=("$product"); DEV_VERSION+=("$version")
            DEV_NAME+=("$name"); DEV_PHYS+=("${phys:--}")
            DEV_SYSFS+=("$sysfs"); DEV_HANDLERS+=("$handlers")
        fi
        bus=""; vendor=""; product=""; version=""
        name=""; phys=""; sysfs=""; handlers=""
    }

    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            "I: "*)
                for kv in ${line#I: }; do
                    case $kv in
                        Bus=*)     bus=${kv#Bus=} ;;
                        Vendor=*)  vendor=${kv#Vendor=} ;;
                        Product=*) product=${kv#Product=} ;;
                        Version=*) version=${kv#Version=} ;;
                    esac
                done ;;
            "N: Name="*)     name=${line#N: Name=}; name=${name//\"/} ;;
            "P: Phys="*)     phys=${line#P: Phys=} ;;
            "S: Sysfs="*)    sysfs=${line#S: Sysfs=} ;;
            "H: Handlers="*) handlers=${line#H: Handlers=}; handlers=${handlers% } ;;
            "")              flush ;;
        esac
    done < "$DEVICES_FILE"
    flush
}

FMT="%-4s %-6s %-7s %-7s %-34s %-26s %s\n"

print_table() {
    printf "$FMT" "Bus" "Vendor" "Product" "Version" "Name" "Phys" "Handlers"
    printf '%.0s-' {1..115}; echo
    local i
    for i in "${!DEV_NAME[@]}"; do
        printf "$FMT" "${DEV_BUS[$i]}" "${DEV_VENDOR[$i]}" "${DEV_PRODUCT[$i]}" \
               "${DEV_VERSION[$i]}" "${DEV_NAME[$i]:0:34}" "${DEV_PHYS[$i]:0:26}" \
               "${DEV_HANDLERS[$i]}"
    done
    echo
    echo "Всего устройств: ${#DEV_NAME[@]}"
}

# Сигнал о новом устройстве (для фонового режима)
signal_new() {
    local msg="Подключено новое устройство: $1"
    printf '\a'                                     # звуковой сигнал терминала
    echo "[$(date '+%H:%M:%S')] $msg" >&2
    command -v logger      >/dev/null && logger -t input_monitor "$msg"
    command -v notify-send >/dev/null && [[ -n ${DISPLAY:-} ]] \
        && notify-send "input_monitor" "$msg"
}

# =============================================================================
# 2.3. Лог: время запуска + только НОВЫЕ устройства (старые не заносятся)
#
# Ключ устройства — путь Sysfs (…/input/inputN). При переподключении ядро
# выдаёт новый номер inputN, поэтому повторное подключение тоже считается новым.
# =============================================================================
check_and_log() {
    local signal=$1
    declare -A known=()
    local first_run=0 k i
    if [[ -f $STATE_FILE ]]; then
        while IFS= read -r k; do known[$k]=1; done < "$STATE_FILE"
    else
        first_run=1
    fi

    local new=()
    for i in "${!DEV_NAME[@]}"; do
        k=${DEV_SYSFS[$i]:-${DEV_NAME[$i]}}
        [[ -n ${known[$k]:-} ]] && continue
        new+=("$(printf "  Name=\"%s\" Bus=%s Vendor=%s Product=%s Handlers=%s Sysfs=%s" \
            "${DEV_NAME[$i]}" "${DEV_BUS[$i]}" "${DEV_VENDOR[$i]}" \
            "${DEV_PRODUCT[$i]}" "${DEV_HANDLERS[$i]}" "${DEV_SYSFS[$i]}")")
        (( signal )) && signal_new "${DEV_NAME[$i]} (${DEV_HANDLERS[$i]})"
    done

    {
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') запуск input_monitor: устройств ${#DEV_NAME[@]}, новых ${#new[@]} ==="
        (( first_run )) && echo "  (первый запуск — заносится исходный список устройств)"
        (( ${#new[@]} )) && printf '%s\n' "${new[@]}"
    } >> "$LOG_FILE"

    for i in "${!DEV_NAME[@]}"; do
        echo "${DEV_SYSFS[$i]:-${DEV_NAME[$i]}}"
    done > "$STATE_FILE"

    NEW_COUNT=${#new[@]}
}

# =============================================================================
# Основная логика
# =============================================================================
case $MODE in
    quiet)
        parse_devices
        check_and_log 0
        ;;
    normal)
        show_input_dir
        parse_devices
        print_table
        check_and_log 0
        echo "Новых устройств: $NEW_COUNT. Лог: $LOG_FILE"
        ;;
    daemon)
        trap 'echo "input_monitor остановлен"; exit 0' INT TERM
        show_input_dir
        parse_devices
        print_table                 # информирование при запуске
        check_and_log 0
        echo "Фоновый режим: проверка каждые ${INTERVAL} с (PID $$). Лог: $LOG_FILE"
        while true; do
            sleep "$INTERVAL"
            parse_devices
            check_and_log 1         # сигнализировать о новых подключениях
        done
        ;;
esac
