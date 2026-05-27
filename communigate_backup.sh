#!/usr/bin/env bash
# === Резервное копирование CommuniGate Pro (Debian 12) ===
#
# Логика:
# 1) архивы создаются локально в /backups/CommuniGate/Day/YYYY-MM-DD;
# 2) 1 числа или с ключом --monthly создаётся локальная месчная копия;
# 3) после локального создания архивы дополнительно копируются в REMOTE_BACKUP_ROOT;
# 4) email-отчёт отправляется через локальный SMTP 127.0.0.1:25 без авторизации.
#
# Важно:
# Скрипт сам НЕ монтирует удалённое хранилище.
# Монтирование должно быть настроено отдельно через /etc/fstab, systemd, autofs,
# rclone service или другой удобный способ.
#
# Перед публикацией на GitHub замените:
#   MAIN_DOMAIN
#   EMAIL_TO
#   EMAIL_FROM
#   REMOTE_BACKUP_ROOT
# на обезличенные значения example.com / admin@example.com / /mnt/communigate_backup.

set -euo pipefail
IFS=$'\n\t'

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

# -------------------- НАСТРОЙКИ --------------------

PROGRAM_INSTALL=(pigz curl rsync tar bc util-linux)
AUTO_INSTALL=false

BASE_DIR="/var/CommuniGate"
DIR_ACCOUNTS="$BASE_DIR/Accounts"
DOMAINS_DIR="$BASE_DIR/Domains"

FOLDER_BASE=(
  "/var/CommuniGate/Settings"
  "/var/CommuniGate/Directory"
  "/var/CommuniGate/SystemLogs"
  "/var/CommuniGate/Submitted"
)

LOCAL_BACKUP_ROOT="/backups/CommuniGate"
LOCAL_DAY_BASE="$LOCAL_BACKUP_ROOT/Day"
LOCAL_MONTHLY_BASE="$LOCAL_BACKUP_ROOT/Monthly"
LOG_DIR="$LOCAL_BACKUP_ROOT/Logs"
STATE_FILE="$LOG_DIR/last_run_state.txt"
LOCKFILE="/run/communigate_backup.lock"

# -------------------- ДОПОЛНИТЕЛЬНОЕ ХРАНИЛИЩЕ --------------------
# Здесь указывается уже доступный путь, куда дополнительно копировать архивы.
#
# Примеры:
#   REMOTE_BACKUP_ROOT="/mnt/communigate_backup"
#   REMOTE_BACKUP_ROOT="/mnt/nfs_backup"
#   REMOTE_BACKUP_ROOT="/mnt/samba_backup"
#   REMOTE_BACKUP_ROOT="/mnt/rclone_backup"
#
# Если REMOTE_REQUIRE_MOUNTPOINT=true, путь обязан быть mountpoint.
# Это защищает от ситуации, когда NFS/Samba/rclone не смонтировались,
# а скрипт начал писать архивы в пустую локальную папку /mnt/....
#
# Если нужно использовать обычную локальную папку или примонтиованнный диск, поставьте:
#   REMOTE_REQUIRE_MOUNTPOINT=false

REMOTE_BACKUP_ENABLED=true
REMOTE_BACKUP_ROOT="/mnt/communigate_backup"
REMOTE_REQUIRE_MOUNTPOINT=true

# Marker-файл защищает от записи не туда.
# Создайте его один раз в целевом хранилище:
#   touch /mnt/communigate_backup/backup_marker_do_not_delete
#
# Если marker не нужен:
#   REMOTE_REQUIRE_MARKER=false

REMOTE_REQUIRE_MARKER=true
REMOTE_MARKER_FILE="$REMOTE_BACKUP_ROOT/backup_marker_do_not_delete"

REMOTE_DAY_BASE="$REMOTE_BACKUP_ROOT/CommuniGate/Day"
REMOTE_MONTHLY_BASE="$REMOTE_BACKUP_ROOT/CommuniGate/Monthly"
REMOTE_LOG_BASE="$REMOTE_BACKUP_ROOT/CommuniGate/Logs"

LOCAL_DAILY_RETENTION_DAYS=4
REMOTE_DAILY_RETENTION_DAYS=14
MONTHLY_RETENTION=3
LOG_RETENTION_COUNT=16

REQUIRED_SPACE_LOCAL=2000
REQUIRED_SPACE_REMOTE=5000

PIGZ_THREADS=4

# -------------------- НАСТРОЙКИ ПОЧТЫ --------------------
# Письмо отправляется через локальный SMTP без авторизации. Укажите в CjmmunuGate localhost как доверенный.

MAIN_DOMAIN="example.com"
EMAIL_TO="admin@example.com"
EMAIL_FROM="backup@example.com"
SMTP_SERVER="smtp://127.0.0.1:25"

# -------------------- ПЕРЕМЕННЫЕ ЗАПУСКА --------------------

START_TS_LOG="$(date '+%Y-%m-%d-%H%M%S')"
START_TS_MAIL="$(date '+%Y-%m-%d %H:%M:%S')"
TODAY="$(date '+%Y-%m-%d')"
DAY_OF_MONTH="$(date '+%d')"

TODAY_DIR="$LOCAL_DAY_BASE/$TODAY"
TODAY_MONTHLY_DIR="$LOCAL_MONTHLY_BASE/$TODAY"
LOG_FILE="$LOG_DIR/backup_${START_TS_LOG}.log"

TOTAL_SIZE=0
CREATED_ARCHIVES=0
ERRORS_IN_RUN=()
CRITICAL_ERROR=false

FREE_SPACE_LOCAL=0
FREE_SPACE_REMOTE=0

CURRENT_RUN_ITEMS=""
NEW_COUNT=0
MISSING_COUNT=0
NEW_ITEMS_LIST=""
MISSING_ITEMS_LIST=""

FORCE_MONTHLY=false
DRY_RUN=false
SEND_REPORT=true

# -------------------- ЛОГИРОВАНИЕ --------------------

log_message() {
  printf '[%s] INFO: %s\n' "$(date '+%F %T')" "$*"
}

log_warn() {
  printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2
}

log_error() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  ERRORS_IN_RUN+=("$*")
}

# -------------------- СПРАВКА И АРГУМЕНТЫ --------------------

usage() {
  cat <<USAGE
Использование:
  $0              обычный запуск
  $0 --monthly    принудительно создать Monthly-копию
  $0 --dry-run    проверка без создания архивов и копирования
  $0 --no-email   не отправлять email-отчёт
  $0 --help       показать справку
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --monthly)
        FORCE_MONTHLY=true
        ;;
      --dry-run)
        DRY_RUN=true
        ;;
      --no-email)
        SEND_REPORT=false
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac

    shift
  done
}

# -------------------- БАЗОВЫЕ ПРОВЕРКИ --------------------

check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Запускайте скрипт от root." >&2
    exit 1
  fi
}

init_log() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"

  # Всё, что пишет скрипт, уходит и на экран, и в лог.
  exec > >(tee -a "$LOG_FILE") 2>&1
}

acquire_lock() {
  mkdir -p /run

  # Блокировка через flock не даёт запустить второй экземпляр скрипта параллельно.
  exec 9>"$LOCKFILE"

  if ! flock -n 9; then
    log_error "Скрипт уже запущен: $LOCKFILE"
    exit 1
  fi
}

cleanup() {
  local rc=$?

  if [[ "$rc" -ne 0 ]]; then
    log_error "Скрипт завершился с ошибкой, код: $rc"
  fi

  exit "$rc"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
  local missing=()

  # Проверяем именно команды, которые реально используются ниже.
  for cmd in pigz curl rsync tar bc flock mountpoint df awk find sort xargs mktemp sed stat basename chmod mkdir rm mv tee; do
    if ! require_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log_message "Все зависимости найдены."
    return 0
  fi

  log_error "Не найдены команды: ${missing[*]}"

  if [[ "$AUTO_INSTALL" != "true" ]]; then
    log_error "Автоустановка отключена. Выполните: apt update && apt install -y ${PROGRAM_INSTALL[*]}"
    exit 1
  fi

  log_message "AUTO_INSTALL=true. Выполняю apt update."
  apt-get update

  log_message "Устанавливаю пакеты: ${PROGRAM_INSTALL[*]}"
  apt-get install -y "${PROGRAM_INSTALL[@]}"
}

# -------------------- ПОДГОТОВКА КАТАЛОГОВ --------------------

prepare_dirs() {
  log_message "Подготовка локальных каталогов."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_message "DRY-RUN: mkdir -p $TODAY_DIR"
    return 0
  fi

  mkdir -p "$TODAY_DIR/accounts" "$TODAY_DIR/domains" "$TODAY_DIR/system" "$LOCAL_MONTHLY_BASE" "$LOG_DIR"
}

# -------------------- ПРОВЕРКА ДОПОЛНИТЕЛЬНОГО ХРАНИЛИЩА --------------------

ensure_remote_storage() {
  if [[ "$REMOTE_BACKUP_ENABLED" != "true" ]]; then
    log_message "Дополнительное хранилище отключено: REMOTE_BACKUP_ENABLED=false"
    return 0
  fi

  log_message "Проверка дополнительного хранилища: $REMOTE_BACKUP_ROOT"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_message "DRY-RUN: проверка дополнительного хранилища пропущена."
    return 0
  fi

  if [[ -z "$REMOTE_BACKUP_ROOT" || "$REMOTE_BACKUP_ROOT" != /* ]]; then
    log_error "REMOTE_BACKUP_ROOT должен быть абсолютным путём."
    CRITICAL_ERROR=true
    return 1
  fi

  if [[ "$REMOTE_REQUIRE_MOUNTPOINT" == "true" ]]; then
    if ! mountpoint -q "$REMOTE_BACKUP_ROOT"; then
      log_error "Дополнительное хранилище не является mountpoint: $REMOTE_BACKUP_ROOT"
      log_error "Если это обычная локальная папка, установите REMOTE_REQUIRE_MOUNTPOINT=false"
      CRITICAL_ERROR=true
      return 1
    fi
  else
    if [[ ! -d "$REMOTE_BACKUP_ROOT" ]]; then
      log_warn "REMOTE_REQUIRE_MOUNTPOINT=false, создаю локальный каталог: $REMOTE_BACKUP_ROOT"
      mkdir -p "$REMOTE_BACKUP_ROOT"
    fi
  fi

  if [[ ! -d "$REMOTE_BACKUP_ROOT" ]]; then
    log_error "Каталог дополнительного хранилища недоступен: $REMOTE_BACKUP_ROOT"
    CRITICAL_ERROR=true
    return 1
  fi

  if [[ "$REMOTE_REQUIRE_MARKER" == "true" ]]; then
    if [[ ! -f "$REMOTE_MARKER_FILE" ]]; then
      log_error "Marker-файл дополнительного хранилища не найден: $REMOTE_MARKER_FILE"
      log_error "Создайте его командой: touch '$REMOTE_MARKER_FILE'"
      CRITICAL_ERROR=true
      return 1
    fi
  fi

  mkdir -p "$REMOTE_DAY_BASE" "$REMOTE_MONTHLY_BASE" "$REMOTE_LOG_BASE"

  log_message "Дополнительное хранилище доступно: $REMOTE_BACKUP_ROOT"
}

check_space() {
  mkdir -p "$LOCAL_BACKUP_ROOT"

  FREE_SPACE_LOCAL="$(df -Pm "$LOCAL_BACKUP_ROOT" | awk 'NR==2 {print $4}')"
  log_message "Свободно локально: ${FREE_SPACE_LOCAL} MB"

  if (( FREE_SPACE_LOCAL < REQUIRED_SPACE_LOCAL )); then
    log_error "Мало места локально: ${FREE_SPACE_LOCAL} MB"
    exit 1
  fi

  if [[ "$REMOTE_BACKUP_ENABLED" == "true" && "$DRY_RUN" != "true" && -d "$REMOTE_BACKUP_ROOT" ]]; then
    FREE_SPACE_REMOTE="$(df -Pm "$REMOTE_BACKUP_ROOT" | awk 'NR==2 {print $4}')"
    log_message "Свободно в дополнительном хранилище: ${FREE_SPACE_REMOTE} MB"

    if (( FREE_SPACE_REMOTE < REQUIRED_SPACE_REMOTE )); then
      log_error "Мало места в дополнительном хранилище: ${FREE_SPACE_REMOTE} MB"
      CRITICAL_ERROR=true
    fi
  fi
}

# -------------------- АРХИВАЦИЯ --------------------

safe_name() {
  local s="$1"

  # Защита имени архива от слешей и переносов строк.
  s="${s//\//_}"
  s="${s//$'\n'/_}"

  printf '%s' "$s"
}

create_archive() {
  local name="$1"
  local src="$2"
  local subdir="$3"

  local dest="$TODAY_DIR/$subdir"
  local target
  local tmp
  local tar_rc
  local archive_name

  if [[ ! -d "$src" ]]; then
    log_error "Папка не найдена: $src"
    return 1
  fi

  archive_name="$(safe_name "$name")_${START_TS_LOG}.tar.gz"
  target="$dest/$archive_name"
  tmp="$target.tmp"

  log_message "Архивация: $src -> $target"

  # В список состояния добавляем объект даже если tar вернёт предупреждение.
  CURRENT_RUN_ITEMS+="$name"$'\n'

  if [[ "$DRY_RUN" == "true" ]]; then
    log_message "DRY-RUN: tar $src"
    return 0
  fi

  mkdir -p "$dest"
  rm -f "$tmp"

  # tar может вернуть 1, если файл изменился во время чтения.
  # Для живого почтового сервера это не всегда критично.
  set +e
  tar \
    --warning=no-file-changed \
    --ignore-failed-read \
    --use-compress-program="pigz -p ${PIGZ_THREADS}" \
    -cf "$tmp" \
    -C / "${src#/}"
  tar_rc=$?
  set -e

  if [[ -s "$tmp" && ( "$tar_rc" -eq 0 || "$tar_rc" -eq 1 ) ]]; then
    if [[ "$tar_rc" -eq 1 ]]; then
      log_warn "tar вернул код 1 для $src: архив создан, но были предупреждения."
    fi

    mv -f "$tmp" "$target"
    chmod 600 "$target"

    TOTAL_SIZE=$(( TOTAL_SIZE + $(stat -c '%s' "$target") ))
    CREATED_ARCHIVES=$(( CREATED_ARCHIVES + 1 ))

    return 0
  fi

  rm -f "$tmp"
  log_error "Ошибка создания архива: $src, код tar: $tar_rc"
  return 1
}

backup_all() {
  local u
  local d_path
  local d_name
  local f

  # nullglob нужен, чтобы шаблон *.macnt не оставался строкой,
  # если таких каталогов нет.
  shopt -s nullglob

  log_message "Архивация основных аккаунтов."

  for u in "$DIR_ACCOUNTS"/*.macnt; do
    if [[ -d "$u" ]]; then
      if ! create_archive "$(basename "$u" .macnt)" "$u" "accounts"; then
        log_warn "Архивация аккаунта завершилась с ошибкой: $u"
      fi
    fi
  done

  log_message "Архивация доменных аккаунтов."

  if [[ -d "$DOMAINS_DIR" ]]; then
    for d_path in "$DOMAINS_DIR"/*; do
      if [[ ! -d "$d_path" ]]; then
        continue
      fi

      d_name="$(basename "$d_path")"

      for u in "$d_path"/*.macnt; do
        if [[ -d "$u" ]]; then
          if ! create_archive "$(basename "$u" .macnt)@$d_name" "$u" "domains/$d_name"; then
            log_warn "Архивация доменного аккаунта завершилась с ошибкой: $u"
          fi
        fi
      done
    done
  else
    log_warn "Каталог доменов не найден: $DOMAINS_DIR"
  fi

  log_message "Архивация системных папок."

  for f in "${FOLDER_BASE[@]}"; do
    if [[ -d "$f" ]]; then
      if ! create_archive "$(basename "$f")" "$f" "system"; then
        log_warn "Архивация системной папки завершилась с ошибкой: $f"
      fi
    else
      log_warn "Папка пропущена: $f"
    fi
  done

  shopt -u nullglob
}

# -------------------- АНАЛИЗ ИЗМЕНЕНИЙ --------------------

analyze_changes() {
  log_message "Анализ изменений состава архивируемых объектов."

  if [[ -f "$STATE_FILE" ]]; then
    NEW_ITEMS_LIST="$(comm -13 <(sort "$STATE_FILE") <(printf '%s' "$CURRENT_RUN_ITEMS" | sort) | grep -v '^$' || true)"
    MISSING_ITEMS_LIST="$(comm -23 <(sort "$STATE_FILE") <(printf '%s' "$CURRENT_RUN_ITEMS" | sort) | grep -v '^$' || true)"

    NEW_COUNT="$(printf '%s' "$NEW_ITEMS_LIST" | grep -c '.' || true)"
    MISSING_COUNT="$(printf '%s' "$MISSING_ITEMS_LIST" | grep -c '.' || true)"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  printf '%s' "$CURRENT_RUN_ITEMS" | sort > "$STATE_FILE"
}

# -------------------- MONTHLY --------------------

create_monthly() {
  log_message "Создание локальной Monthly-копии: $TODAY_MONTHLY_DIR"

  if [[ ! -d "$TODAY_DIR" ]]; then
    log_error "Нет дневного бэкапа: $TODAY_DIR"
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_message "DRY-RUN: Monthly из $TODAY_DIR"
    return 0
  fi

  mkdir -p "$TODAY_MONTHLY_DIR"

  rsync \
    -rtv \
    --delete \
    --no-owner \
    --no-group \
    --no-perms \
    --omit-dir-times \
    "$TODAY_DIR/" "$TODAY_MONTHLY_DIR/"
}

# -------------------- ПЕРЕНОС В ДОПОЛНИТЕЛЬНОЕ ХРАНИЛИЩЕ --------------------

sync_to_remote() {
  local src="$1"
  local dst="$2"
  local label="$3"

  if [[ "$REMOTE_BACKUP_ENABLED" != "true" ]]; then
    log_message "Дополнительное хранилище отключено, пропуск: $label"
    return 0
  fi

  if [[ ! -d "$src" && "$DRY_RUN" != "true" ]]; then
    log_error "Нет источника для $label: $src"
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_message "DRY-RUN: rsync $src/ -> $dst/"
    return 0
  fi

  if [[ ! -d "$REMOTE_BACKUP_ROOT" ]]; then
    log_error "Дополнительное хранилище недоступно, перенос невозможен: $label"
    CRITICAL_ERROR=true
    return 1
  fi

  if [[ "$REMOTE_REQUIRE_MOUNTPOINT" == "true" ]] && ! mountpoint -q "$REMOTE_BACKUP_ROOT"; then
    log_error "Дополнительное хранилище больше не является mountpoint: $REMOTE_BACKUP_ROOT"
    CRITICAL_ERROR=true
    return 1
  fi

  mkdir -p "$dst"

  log_message "Перенос в дополнительное хранилище: $label"

  # Не используем rsync -a:
  # remote storage может быть FTP/rclone, CIFS, NFS или другой FUSE,
  # где chown/chmod/hardlinks могут не поддерживаться.
  rsync \
    -rtv \
    --delete \
    --no-owner \
    --no-group \
    --no-perms \
    --omit-dir-times \
    --timeout=300 \
    "$src/" "$dst/" || {
      log_error "Ошибка переноса в дополнительное хранилище: $label"
      CRITICAL_ERROR=true
      return 1
    }
}

# -------------------- РОТАЦИЯ --------------------

rotate_backups() {
  log_message "Ротация локальных и remote-копий."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_message "DRY-RUN: ротация пропущена."
    return 0
  fi

  find "$LOCAL_DAY_BASE" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +"$LOCAL_DAILY_RETENTION_DAYS" \
    -exec rm -rf {} +

  find "$LOCAL_MONTHLY_BASE" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    | sort -r \
    | tail -n +$((MONTHLY_RETENTION + 1)) \
    | xargs -r rm -rf

  find "$LOG_DIR" \
    -name 'backup_*.log' \
    -type f \
    | sort -r \
    | tail -n +$((LOG_RETENTION_COUNT + 1)) \
    | xargs -r rm -f

  if [[ "$REMOTE_BACKUP_ENABLED" == "true" && -d "$REMOTE_BACKUP_ROOT" ]]; then
    if [[ "$REMOTE_REQUIRE_MOUNTPOINT" != "true" || $(mountpoint -q "$REMOTE_BACKUP_ROOT"; echo $?) -eq 0 ]]; then
      find "$REMOTE_DAY_BASE" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -mtime +"$REMOTE_DAILY_RETENTION_DAYS" \
        -exec rm -rf {} + 2>/dev/null || true

      find "$REMOTE_MONTHLY_BASE" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d 2>/dev/null \
        | sort -r \
        | tail -n +$((MONTHLY_RETENTION + 1)) \
        | xargs -r rm -rf

      find "$REMOTE_LOG_BASE" \
        -name 'backup_*.log' \
        -type f 2>/dev/null \
        | sort -r \
        | tail -n +$((LOG_RETENTION_COUNT + 1)) \
        | xargs -r rm -f
    fi
  fi
}

# -------------------- EMAIL БЕЗ АВТОРИЗАЦИИ --------------------

send_email_report() {
  local status="$1"
  local msg="$2"

  local end_ts
  local size_gb
  local extra=""
  local errors=""
  local mail_tmp
  local curl_rc=0

  if [[ "$SEND_REPORT" != "true" ]]; then
    log_message "Отправка email отключена параметром --no-email."
    return 0
  fi

  if ! require_cmd curl || ! require_cmd bc || ! require_cmd mktemp; then
    log_error "curl, bc или mktemp не найдены, email не отправлен."
    return 1
  fi

  end_ts="$(date '+%Y-%m-%d %H:%M:%S')"
  size_gb="$(bc <<< "scale=2; $TOTAL_SIZE / 1073741824")"

  if [[ "$NEW_COUNT" -gt 0 ]]; then
    extra+="<p style='color:green;'><b>Добавлены:</b><br>${NEW_ITEMS_LIST//$'\n'/<br>}</p>"
  fi

  if [[ "$MISSING_COUNT" -gt 0 ]]; then
    extra+="<p style='color:red;'><b>Пропущены/удалены:</b><br>${MISSING_ITEMS_LIST//$'\n'/<br>}</p>"
  fi

  if [[ ${#ERRORS_IN_RUN[@]} -gt 0 ]]; then
    errors="<p style='color:red;'><b>Ошибки:</b><br>$(printf '%s\n' "${ERRORS_IN_RUN[@]}" | sed 's/$/<br>/')</p>"
  fi

  mail_tmp="$(mktemp /tmp/communigate-backup-mail.XXXXXX)"

  {
    echo "From: <${EMAIL_FROM}>"
    echo "To: <${EMAIL_TO}>"
    echo "Subject: [Backup] ${status}: ${MAIN_DOMAIN} - ${TODAY}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/html; charset=UTF-8"
    echo ""
    cat <<HTML
<html>
<body style="font-family:Arial;">
<h2>Отчёт резервного копирования CommuniGate</h2>

<table border="0" cellpadding="5" style="border-collapse:collapse;">
<tr><td><b>Статус:</b></td><td>${status}</td></tr>
<tr><td><b>Сообщение:</b></td><td>${msg}</td></tr>
<tr><td><b>Начало:</b></td><td>${START_TS_MAIL}</td></tr>
<tr><td><b>Конец:</b></td><td>${end_ts}</td></tr>
<tr><td><b>Создано архивов:</b></td><td>${CREATED_ARCHIVES}</td></tr>
<tr><td><b>Размер:</b></td><td>${size_gb} GB</td></tr>
<tr><td><b>Локально Day:</b></td><td>${TODAY_DIR}</td></tr>
<tr><td><b>Локально Monthly:</b></td><td>${TODAY_MONTHLY_DIR}</td></tr>
<tr><td><b>Remote Day:</b></td><td>${REMOTE_DAY_BASE}/${TODAY}</td></tr>
<tr><td><b>Remote Monthly:</b></td><td>${REMOTE_MONTHLY_BASE}/${TODAY}</td></tr>
<tr><td><b>Свободно локально:</b></td><td>${FREE_SPACE_LOCAL} MB</td></tr>
<tr><td><b>Свободно remote:</b></td><td>${FREE_SPACE_REMOTE} MB</td></tr>
<tr><td><b>Лог:</b></td><td>${LOG_FILE}</td></tr>
</table>

${extra}
${errors}

</body>
</html>
HTML
  } > "$mail_tmp"

  chmod 600 "$mail_tmp"

  log_message "Отправка email-отчёта через локальный SMTP без авторизации: ${SMTP_SERVER}"

  curl \
    --fail \
    --silent \
    --show-error \
    --url "$SMTP_SERVER" \
    --mail-from "$EMAIL_FROM" \
    --mail-rcpt "$EMAIL_TO" \
    --upload-file "$mail_tmp" || curl_rc=$?

  rm -f "$mail_tmp"

  if [[ "$curl_rc" -ne 0 ]]; then
    log_error "Email-отчёт не отправлен. curl завершился с кодом: $curl_rc"
    return "$curl_rc"
  fi

  log_message "Email-отчёт успешно отправлен."
  return 0
}

# -------------------- MAIN --------------------

main() {
  parse_args "$@"
  check_root
  init_log

  trap cleanup EXIT INT TERM SIGHUP

  acquire_lock

  log_message "=== СТАРТ БЭКАПА ==="
  log_message "TODAY=$TODAY DAY_OF_MONTH=$DAY_OF_MONTH FORCE_MONTHLY=$FORCE_MONTHLY DRY_RUN=$DRY_RUN"
  log_message "REMOTE_BACKUP_ENABLED=$REMOTE_BACKUP_ENABLED REMOTE_BACKUP_ROOT=$REMOTE_BACKUP_ROOT"

  check_dependencies
  prepare_dirs
  ensure_remote_storage || true
  check_space

  backup_all
  analyze_changes

  # Monthly создаётся ДО переноса в дополнительное хранилище.
  if [[ "$DAY_OF_MONTH" == "01" || "$FORCE_MONTHLY" == "true" ]]; then
    create_monthly || CRITICAL_ERROR=true
  else
    log_message "Monthly сегодня не создаётся. Для проверки: $0 --monthly"
  fi

  # Перенос Day в дополнительное хранилище.
  sync_to_remote "$TODAY_DIR" "$REMOTE_DAY_BASE/$TODAY" "Day $TODAY" || true

  # Перенос Monthly в дополнительное хранилище, если он создан.
  if [[ -d "$TODAY_MONTHLY_DIR" || "$FORCE_MONTHLY" == "true" || "$DAY_OF_MONTH" == "01" ]]; then
    sync_to_remote "$TODAY_MONTHLY_DIR" "$REMOTE_MONTHLY_BASE/$TODAY" "Monthly $TODAY" || true
  fi

  # Копируем текущий лог в дополнительное хранилище.
  if [[ "$REMOTE_BACKUP_ENABLED" == "true" && "$DRY_RUN" != "true" && -d "$REMOTE_LOG_BASE" ]]; then
    rsync \
      -rtv \
      --no-owner \
      --no-group \
      --no-perms \
      --omit-dir-times \
      "$LOG_FILE" "$REMOTE_LOG_BASE/" || true
  fi

  rotate_backups

  local status="SUCCESS"
  local msg="Бэкап успешно завершён"

  if [[ "$CRITICAL_ERROR" == "true" ]]; then
    status="CRITICAL"
    msg="Бэкап завершён с критическими ошибками. Проверьте лог: $LOG_FILE"
  elif [[ ${#ERRORS_IN_RUN[@]} -gt 0 ]]; then
    status="WARNING"
    msg="Бэкап завершён с предупреждениями. Проверьте лог: $LOG_FILE"
  fi

  if ! send_email_report "$status" "$msg"; then
    log_error "Основной бэкап завершён, но email-уведомление не отправлено."

    if [[ "$status" == "SUCCESS" ]]; then
      status="WARNING"
      msg="Бэкап завершён успешно, но email-уведомление не отправлено"
    fi
  fi

  log_message "=== КОНЕЦ: $status ==="
}

main "$@"
