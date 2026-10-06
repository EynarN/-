#!/usr/bin/env bash
# =============================================================================
# proc_monitor.sh — мониторинг процессов через директорию /proc
#
# Использование:
#   ./proc_monitor.sh        — вывести таблицу процессов и записать новые в лог
#   ./proc_monitor.sh -q     — «тихий» режим для cron: только запись в лог
#
# Для полного доступа к /proc/N/exe, /proc/N/cwd, /proc/N/fd чужих процессов
# запускать от root (sudo). Без root по чужим процессам будет «-».
# =============================================================================

set -u

QUIET=0
[[ "${1:-}" == "-q" ]] && QUIET=1

# --- Где хранить лог и список уже известных процессов -----------------------
LOG_DIR="${LOG_DIR:-/var/log/proc_monitor}"
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
    LOG_DIR="$HOME/.local/state/proc_monitor"      # нет прав на /var/log
    mkdir -p "$LOG_DIR"
fi
LOG_FILE="$LOG_DIR/proc_monitor.log"
STATE_FILE="$LOG_DIR/known_processes.state"

# =============================================================================
# 1.1. Просмотр /proc и сбор номерных директорий (номер директории = PID)
# =============================================================================
get_pids() {
    local dir pid
    for dir in /proc/[0-9]*; do
        pid=${dir#/proc/}
        [[ $pid =~ ^[0-9]+$ ]] && echo "$pid"
    done | sort -n
}

# =============================================================================
# 1.2. Имя процесса через /proc/N/exe (символическая ссылка на исполняемый файл)
# =============================================================================
get_name() {
    local pid=$1 exe comm
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    if [[ -n $exe ]]; then
        exe=${exe% (deleted)}              # бинарник мог быть удалён/обновлён
        echo "${exe##*/}"                  # оставляем только имя файла
    else
        # У потоков ядра exe пустой, к чужим процессам без root нет доступа —
        # тогда берём короткое имя из /proc/N/comm и помечаем скобками
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) && echo "[$comm]" || echo "?"
    fi
}

# =============================================================================
# 1.3. Группа параметров процесса (4 параметра):
#      State   — состояние процесса        (/proc/N/status)
#      FDs     — число открытых дескрипторов (/proc/N/fd)
#      CWD     — текущая рабочая директория (/proc/N/cwd)
#      Cmdline — командная строка запуска   (/proc/N/cmdline)
# =============================================================================
get_state() {
    awk '/^State:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null || echo "-"
}

get_fd_count() {
    if [[ -r "/proc/$1/fd" ]]; then
        ls -1 "/proc/$1/fd" 2>/dev/null | wc -l
    else
        echo "-"
    fi
}

get_cwd() {
    local cwd
    cwd=$(readlink "/proc/$1/cwd" 2>/dev/null)
    echo "${cwd:--}"
}

get_cmdline() {
    local cmd
    # аргументы в cmdline разделены нулевыми байтами — меняем их на пробелы
    cmd=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    cmd=${cmd% }
    echo "${cmd:--}"
}

# Время старта процесса (поле 22 в /proc/N/stat). Пара PID+starttime
# уникальна: если PID освободится и достанется новому процессу, мы это увидим.
get_starttime() {
    local stat rest
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    rest=${stat##*) }                      # имя в скобках может содержать пробелы
    read -ra f <<< "$rest"
    echo "${f[19]}"                        # rest начинается с поля 3 → 22-3=19
}

# =============================================================================
# 1.4. Цикл: собираем данные и оформляем таблицу
# =============================================================================
FMT="%-7s %-20s %-5s %-5s %-28s %s\n"

rows=()        # строки таблицы
keys=()        # ключи PID:starttime для лога
names=()

for pid in $(get_pids); do
    [[ -d /proc/$pid ]] || continue        # процесс мог завершиться за время цикла
    st=$(get_starttime "$pid") || continue

    name=$(get_name "$pid")
    state=$(get_state "$pid")
    fds=$(get_fd_count "$pid")
    cwd=$(get_cwd "$pid")
    cmd=$(get_cmdline "$pid")

    rows+=("$(printf "$FMT" "$pid" "${name:0:20}" "$state" "$fds" "${cwd:0:28}" "${cmd:0:60}")")
    keys+=("$pid:$st")
    names+=("$pid|$name|$state|$fds|$cwd|$cmd")
done

# =============================================================================
# 1.5. Лог: время запуска + только НОВЫЕ процессы (старые не заносятся)
# =============================================================================
declare -A known=()
first_run=0
if [[ -f $STATE_FILE ]]; then
    while IFS= read -r k; do known[$k]=1; done < "$STATE_FILE"
else
    first_run=1
fi

new_entries=()
for i in "${!keys[@]}"; do
    [[ -n ${known[${keys[$i]}]:-} ]] && continue
    IFS='|' read -r p n s f c cmd <<< "${names[$i]}"
    new_entries+=("$(printf "  PID=%-7s Name=%-20s State=%s FDs=%s CWD=%s Cmd=%s" \
                    "$p" "$n" "$s" "$f" "$c" "${cmd:0:100}")")
done

{
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') запуск proc_monitor: процессов ${#keys[@]}, новых ${#new_entries[@]} ==="
    (( first_run )) && echo "  (первый запуск — заносится исходный список процессов)"
    (( ${#new_entries[@]} )) && printf '%s\n' "${new_entries[@]}"
} >> "$LOG_FILE"

# Текущий список становится «известным» для следующего запуска
printf '%s\n' "${keys[@]}" > "$STATE_FILE"

# Вывод таблицы (после записи лога — чтобы обрыв вывода, например через
# "| head", не помешал логированию)
if (( ! QUIET )); then
    printf "$FMT" "PID" "Name" "State" "FDs" "CWD" "Cmdline"
    printf '%.0s-' {1..110}; echo
    printf '%s\n' "${rows[@]}"
    echo
    echo "Всего процессов: ${#rows[@]}"
fi

(( QUIET )) || echo "Новых процессов: ${#new_entries[@]}. Лог: $LOG_FILE"
