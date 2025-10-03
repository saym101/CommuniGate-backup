#!/bin/bash
# shellcheck disable=SC2155
# Это отключит предупреждения о declare and assign для readonly переменных
# shellcheck verified - все предупреждения исправлены
# -------------------------------------------------------------------
# CommuniGate Pro Backup Script
# Purpose: Creates daily and monthly backups of CommuniGate Pro data,
#          uploads them to an FTP server, cleans up old backups (local and FTP),
#          and sends email notifications.
# Usage: Configure the variables in "User Configuration" section below,
#        then run the script daily via cron (e.g., `0 2 * * * /path/to/communigate_backup.sh`).
# Requirements: bash, tar, curl, base64, pigz (optional for faster compression).
# License: MIT (use, modify, and distribute freely with attribution).
# -------------------------------------------------------------------

set -euo pipefail

# Скрипт зависит от этих программ. Их необходимо установить при первом запуске скрипта. потом можно закомментировать.
 apt -y install pigz curl rsync tar bc

# Проверка на root вынесена в самое начало для большей ясности.
if [[ "$EUID" -ne 0 ]]; then
    echo "Скрипт не запущен от root. :( Перезапускаю через su..."
    # Используем exec, чтобы заменить текущий процесс, а не создавать дочерний.
    exec su -c "bash '$0' $*" root
fi
echo "Скрипт запущен от root. Продолжаю работу :)"

# -------------------- КОНФИГУРАЦИЯ ПОЛЬЗОВАТЕЛЯ --------------------
# Эти переменные необходимо настроить под ваш сервер.

PROGRAM_INSTALL=(pigz curl rsync tar bc)
AUTO_INSTALL=false	# Запускать проверку для установки программ или нет.
DEBUG=false  # Можно выставить в true для отладки
FAILED_ARCHIVES_LIST=""

BASE_DIR="/var/CommuniGate"
BACKUP_BASE="/backups/CommuniGate/Day"
MONTHLY_BACKUP_DIR="/backups/CommuniGate/Monthly"
DOMAINS_DIR="$BASE_DIR/Domains"

SHARA="/mnt/share/"
SHARA_DIR_DAY="/CommuniGate/Day"
SHARA_DIR_MONTHLY="/CommuniGate/Monthly"

RETENTION_DAYS=6
MONTHLY_RETENTION=3

START_TS=$(date "+%Y-%m-%d-%H%M%S")
TODAY=$(date +%Y-%m-%d)
TODAY_DIR="$BACKUP_BASE/$TODAY"

LOG_DIR="/backups/CommuniGate/Logs"
LOG_FILE="$LOG_DIR/backup_${START_TS}.log"

MAIN_DOMAIN="example.com" # Свой домен сюда

FOLDER_BASE=(
    "/var/CommuniGate/Settings"
    "/var/CommuniGate/Directory"
    "/var/CommuniGate/SystemLogs"
    "/var/CommuniGate/Submitted"
)
#    "/var/CommuniGate/CGP-KAS" # Перенести выше в массив, если нужны. Или добавить свои.
#    "/var/CommuniGate/CGP-KAV"


EMAIL_TO="admin@example.com" # адрес postmaster
EMAIL_FROM="backup@example.com" # адрес postmaster
SMTP_SERVER="smtp://127.0.0.1:25"
# SMTP_USER="" # для использования не локального почтового серера. в функции send_email заменить строку для отправки.
# SMTP_PASS=""

REQUIRED_SPACE=2000 # Мб минимум свободного места (пример)
ARCHIVE_RETRY_COUNT=4      # Общее количество попыток архивации
ARCHIVE_RETRY_DELAY_SECONDS=5 # Пауза в секундах между попытками

##################################################
# Глобальные переменные для отчёта
SENT_FILES=0
SENT_FILES_LIST=""
TOTAL_SIZE=0
ERRORS_IN_RUN=()
free_space=0
ACCOUNTS_MISSING_ARCHIVES="" # Хранит список пропущенных пользователей

##################################################
# Логирование
log_message() {
    echo "[$(date '+%F %T')] INFO: $*"
}
log_error() {
    echo "[$(date '+%F %T')] ERROR: $*" >&2
    ERRORS_IN_RUN+=("$*")
}
log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "[$(date '+%F %T')] DEBUG: $*"
    fi
}
# только для ошибок архивации
log_archive_failure() {
    echo "[$(date '+%F %T')] ERROR: $*" >&2
    # Добавляем ошибку в ОБЩИЙ список для статуса WARNING
    ERRORS_IN_RUN+=("$*")
    # И отдельно добавляем путь в СПЕЦИАЛЬНЫЙ список для отчёта
    FAILED_ARCHIVES_LIST+="<li>$2</li>"
}
##################################################
# Проверка установки нужных программ
check_dependencies() {
    log_message "Проверка зависимостей..."
    local missing_deps=()
    for dep in "${PROGRAM_INSTALL[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if (( ${#missing_deps[@]} > 0 )); then
        log_error "Не установлены следующие зависимости: ${missing_deps[*]}"
        if [[ "$AUTO_INSTALL" == "true" ]]; then
            log_message "Попытка автоматической установки через apt..."
            if apt -y install "${missing_deps[@]}" >> "$LOG_FILE" 2>&1; then
                log_message "Все зависимости успешно установлены."
            else
                log_error "Ошибка при установке зависимостей. Прекращаю выполнение."
                exit 1
            fi
        else
            log_error "Автоустановка отключена. Пожалуйста, установите зависимости вручную."
            exit 1
        fi
    fi
    log_message "Все зависимости на месте."
}

##################################################
# Проверка целостности архивов
verify_archive() {
    local archive="$1"
	local archive_name
	archive_name=$(basename "$archive")
    
    log_message "Проверка целостности архива: $archive_name"
    
    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        log_error "Архив поврежден или невалиден: $archive_name"
        return 1
    fi
    
    log_debug "Архив прошел проверку целостности: $archive_name"
    return 0
}

##################################################
# Проверка размера архивов (защита от пустых архивов)
check_archive_size() {
    local archive="$1"
    local min_size=1024
    local size
    size=$(stat -c%s "$archive" 2>/dev/null || echo 0)
    
    if [[ $size -lt $min_size ]]; then
        log_error "Архив подозрительно мал: $archive ($size bytes)"
        return 1
    fi
    
    return 0
}

##################################################
# Валидация всех созданных архивов
validate_all_archives() {
    log_message "Начинаю валидацию созданных архивов..."
    local invalid_count=0
    local total_archives=0
    
    for archive in "$TODAY_DIR"/*.tar.gz; do
        [[ -f "$archive" ]] || continue
        ((total_archives++))
        
        if ! verify_archive "$archive" || ! check_archive_size "$archive"; then
            ((invalid_count++))
            # Помечаем проблемный архив
            mv "$archive" "${archive}.INVALID" 2>/dev/null || true
        fi
    done
    
    if [[ $invalid_count -gt 0 ]]; then
        log_error "Найдено $invalid_count невалидных архивов из $total_archives"
        return 1
    fi
    
    log_message "Все $total_archives архивов прошли валидацию успешно"
    return 0
}

##################################################
# Обработка прерываний
cleanup() {
    log_message "Получен сигнал прерывания. Завершаю работу..."
    # Помечаем бэкап как неполный
    local incomplete_dir="${TODAY_DIR}_INCOMPLETE"
    mv "$TODAY_DIR" "$incomplete_dir" 2>/dev/null || true
    send_email "INTERRUPTED" "Резервное копирование было прервано сигналом"
    exit 1
}

# Регистрируем обработчики сигналов
trap cleanup SIGTERM SIGINT SIGHUP

##################################################
# Проверка доступности шары
##################################################
# Проверка и монтирование сетевой шары
check_share_availability() {
    log_message "Проверяю доступность сетевой шары по пути: $SHARA"
    
    # Если точка не смонтирована, пытаемся монтировать
    if ! mountpoint -q "$SHARA"; then
        log_message "Точка монтирования $SHARA не активна. Пытаюсь монтировать..."
        
        # Проверяем существование директории
        if [[ ! -d "$SHARA" ]]; then
            mkdir -p "$SHARA"
            log_message "Создана директория для монтирования: $SHARA"
        fi
        
        # Пытаемся монтировать (замените на вашу команду монтирования)
        if mount "$SHARA" 2>/dev/null; then
            log_message "Шара успешно смонтирована"
        else
            log_error "Не удалось смонтировать сетевую шару $SHARA"
            return 1
        fi
    fi
    
    # Проверяем возможность записи
    local test_file
    test_file="${SHARA}/.write_test_$(date +%s)"
    if ! touch "$test_file" 2>/dev/null; then
        log_error "Нет прав на запись в сетевую шару $SHARA."
        return 1
    fi
    rm -f "$test_file"
    
    log_message "Сетевая шара доступна и готова к записи."
    return 0
}

##################################################
# Создание архива с механизмом повтора
create_archive() {
    local archive_name="$1"
    local source_path="$2"
    local archive_path="$TODAY_DIR/${START_TS}_${archive_name}.tar.gz"

    log_message "Архивация: $source_path -> $archive_path"

    # Проверяем, существует ли исходная директория
    if [[ ! -d "$source_path" ]]; then
        log_error "Исходная директория не найдена, пропускаю: $source_path"
        return
    fi
    # Проверяем, не пустая ли директория
    if [[ -z "$(find "$source_path" -mindepth 1 -print -quit)" ]]; then
        log_message "Директория пуста, пропускаю: $source_path"
        return
    fi

    local attempt
    local success=false
    # Цикл повторных попыток
    for attempt in $(seq 1 "$ARCHIVE_RETRY_COUNT"); do
        # Пытаемся заархивировать
        if tar --use-compress-program="pigz -p $(nproc)" -cf "$archive_path" -C / "${source_path:1}"; then
            # Если успешно, выходим из цикла
            success=true
            break
        fi

        # Если попытка не удалась и она не последняя
        if [[ "$attempt" -lt "$ARCHIVE_RETRY_COUNT" ]]; then
            log_message "Попытка $attempt не удалась для $source_path. Повтор через $ARCHIVE_RETRY_DELAY_SECONDS сек..."
            sleep "$ARCHIVE_RETRY_DELAY_SECONDS"
        fi
    done

    # Проверяем итоговый результат
    if [[ "$success" == "true" ]]; then
        log_message "Архив успешно создан: $archive_path"
        SENT_FILES=$((SENT_FILES + 1))
        local size_bytes
        size_bytes=$(stat -c%s "$archive_path")
        TOTAL_SIZE=$((TOTAL_SIZE + size_bytes))
        SENT_FILES_LIST+="<li>$(basename "$archive_path") ($((size_bytes / 1024 / 1024)) MB)</li>"
    else
        # Если все попытки провалились, логируем ошибку
    log_archive_failure "Ошибка создания архива для $source_path после $ARCHIVE_RETRY_COUNT попыток." "$source_path"
    fi
}

##################################################
# Архивация Domains (каждая папка отдельно)
archive_domains() {
    log_message "Начинаю архивацию доменов из $DOMAINS_DIR"
    for domain in "$DOMAINS_DIR"/*; do
        [[ -d "$domain" ]] || continue
        create_archive "Domains_$(basename "$domain")" "$domain"
    done
    log_message "Завершил архивацию доменов."
}

##################################################
# Архивация Accounts
archive_accounts() {
    log_message "Начинаю архивацию почтовых ящиков из $BASE_DIR/Accounts"
    local accounts_dir="$BASE_DIR/Accounts"
    if [[ ! -d "$accounts_dir" ]]; then
        log_error "Папка $accounts_dir не найдена! Архивация ящиков невозможна."
        return 1
    fi

    for user_dir in "$accounts_dir"/*; do
        [[ -d "$user_dir" ]] || continue
        create_archive "Account_$(basename "$user_dir")" "$user_dir"
    done
    log_message "Завершил архивацию почтовых ящиков."
}

##################################################
# Проверка полноты архивации аккаунтов
check_accounts_archives() {
    local accounts_dir="$BASE_DIR/Accounts"
    # Сразу выходим, если директории нет.
    [[ -d "$accounts_dir" ]] || return

    mapfile -t user_dirs < <(find "$accounts_dir" -mindepth 1 -maxdepth 1 -type d)
    mapfile -t archives < <(find "$TODAY_DIR" -maxdepth 1 -type f -name "*_Account_*.tar.gz")

    log_message "Найдено пользователей в $accounts_dir: ${#user_dirs[@]}"
    log_message "Создано архивов Account_*: ${#archives[@]}"

    if (( ${#user_dirs[@]} != ${#archives[@]} )); then
        log_error "Внимание! Количество архивов аккаунтов не совпадает с количеством папок пользователей."
        local missing=()
        for user_path in "${user_dirs[@]}"; do
            local user_name
            user_name=$(basename "$user_path")
            # Используем glob для поиска, т.к. START_TS известен.
            if ! ls "${TODAY_DIR}/${START_TS}_Account_${user_name}.tar.gz" >/dev/null 2>&1; then
                missing+=("$user_name")
            fi
        done

        if (( ${#missing[@]} > 0 )); then
            ACCOUNTS_MISSING_ARCHIVES=$(IFS=,; echo "${missing[*]}")
            log_error "Не созданы архивы для пользователей: $ACCOUNTS_MISSING_ARCHIVES"
        fi
    else
        log_message "Все папки пользователей успешно заархивированы."
    fi
}

##################################################
# Архивация остальных папок из массива FOLDER_BASE
archive_other_folders() {
    log_message "Начинаю архивацию системных папок"
    for folder in "${FOLDER_BASE[@]}"; do
        create_archive "$(basename "$folder")" "$folder"
    done
    log_message "Завершил архивацию системных папок."
}

##################################################
# Ежемесячное копирование
monthly_archive() {
    if [[ "$(date +%d)" != "01" ]]; then
        return
    fi
    log_message "Первое число месяца. Выполняется ежемесячное копирование."
    local monthly_dir="$MONTHLY_BACKUP_DIR/$TODAY"
    mkdir -p "$monthly_dir"
    # Копируем созданные СЕГОДНЯ архивы
    if ! cp -aL "$TODAY_DIR"/* "$monthly_dir/"; then
        log_error "Ошибка при копировании архивов в ежемесячную папку $monthly_dir"
    else
        log_message "Ежемесячный бэкап успешно скопирован в $monthly_dir"
    fi
}

##################################################
# Загрузка архивов на сетевую шару (универсальная): src -> dst, label для логов
upload_to_shara() {
    local src="${1:-$BACKUP_BASE}"
    local dst="${2:-${SHARA}${SHARA_DIR_DAY}}"
    local label="${3:-Дневные}"

    log_message "Начинаю загрузку ${label,,} архивов на сетевую шару"

    if ! check_share_availability; then
        log_error "Сетевая шара недоступна — ${label,,} архивы остаются только локально"
        return 1
    fi

    mkdir -p "$dst"

    if [[ -z "$(find "$src" -name '*.tar.gz' -type f 2>/dev/null)" ]]; then
        log_message "Архивы для загрузки не найдены в $src"
        return 1
    fi

    if rsync -avz --delete --timeout=300 "$src/" "$dst/"; then
        log_message "${label} архивы успешно загружены на сетевую шару."
        return 0
    else
        log_error "Ошибка при загрузке ${label,,} архивов на сетевую шару."
        return 1
    fi
}

##################################################
# Ротация архивов по количеству
rotate_by_count() {
    local path="$1"
    local max_keep="$2"
    log_message "Ротация: оставляем $max_keep последних бэкапов в $path"
    local dirs_to_delete
    mapfile -t dirs_to_delete < <(find "$path" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((max_keep + 1)))
    if (( ${#dirs_to_delete[@]} > 0 )); then
        log_message "Найдено ${#dirs_to_delete[@]} старых директорий для удаления."
        for old_dir in "${dirs_to_delete[@]}"; do
            if [[ -d "$old_dir" ]]; then
                rm -rf "$old_dir"
                log_message "Удалена старая папка: $old_dir"
            fi
        done
    else
        log_message "Ротация не требуется."
    fi
}

##################################################
# Ротация логов
rotate_logs() {
    local max_keep=14
    log_message "Ротация логов в $LOG_DIR (оставляем $max_keep файлов)"
    find "$LOG_DIR" -type f -name 'backup_*.log' | sort -r | tail -n +$((max_keep + 1)) | xargs -r rm -f
}

##################################################
# Проверка свободного места
check_free_space() {
    log_message "Проверка свободного места..."
    free_space=$(df -m "$BACKUP_BASE" | tail -1 | awk '{print $4}')
    log_message "Свободное место для бэкапов: ${free_space} МБ."
    if (( free_space < REQUIRED_SPACE )); then
        log_error "Недостаточно места на диске ($free_space МБ), требуется минимум $REQUIRED_SPACE МБ"
        send_email "FATAL" "Недостаточно места на диске для создания бэкапа: $free_space МБ. Процесс прерван."
        exit 1
    fi
}

##################################################
# Отправка почты
send_email() {
    local status="$1"
    local message="$2"
    local subject
    subject="[CommuniGate Backup] $status: $MAIN_DOMAIN - $(date +%F)"
    local total_size_mb
    total_size_mb=$(echo "scale=2; $TOTAL_SIZE / 1024 / 1024" | bc)

    # Добавляем детальный список ошибок в письмо.
    local error_details=""
    if (( ${#ERRORS_IN_RUN[@]} > 0 )); then
        error_details+="<h3>Errors and Warnings</h3>"
        error_details+="<pre style='background-color:#f8d7da; color:#721c24; padding:10px; border:1px solid #f5c6cb; border-radius:5px;'>"
        for error in "${ERRORS_IN_RUN[@]}"; do
            error_details+="$error<br>"
        done
        error_details+="</pre>"
    fi

    local html_body
    html_body=$(cat <<EOF
<html>
<body style="font-family: Arial, sans-serif;">
<h2>Отчёт о резервном копировании CommuniGate</h2>
<table border='1' cellpadding='5' cellspacing='0' style='border-collapse: collapse;'>
  <tr style="background-color: #f2f2f2;"><th>Параметр</th><th>Значение</th></tr>
  <tr><td><b>Статус</b></td><td><b>${status}</b></td></tr>
  <tr><td>Сообщение</td><td>${message}</td></tr>
  <tr><td>Время начала</td><td>${START_TS}</td></tr>
  <tr><td>Время окончания</td><td>$(date '+%Y-%m-%d %H:%M:%S')</td></tr>
  <tr><td>Создано архивов</td><td>${SENT_FILES}</td></tr>
  <tr><td>Общий размер</td><td>${total_size_mb} MB</td></tr>
  <tr><td>Свободно на диске</td><td>${free_space} МБ</td></tr>
  ${ACCOUNTS_MISSING_ARCHIVES:+"<tr><td>Пропущенные аккаунты</td><td style='color:red;'>${ACCOUNTS_MISSING_ARCHIVES}</td></tr>"}
</table>
<h3>Список созданных архивов</h3>
<ul>${SENT_FILES_LIST:-"<li>Архивы не созданы</li>"}</ul>
${error_details}
${FAILED_ARCHIVES_LIST:+<h3>Не удалось заархивировать</h3><ul>${FAILED_ARCHIVES_LIST}</ul>}
<p>Полный лог-файл доступен на сервере: ${LOG_FILE}</p>
</body>
</html>
EOF
)
    # Отправляем письмо через curl
    (
        echo "From: CommuniGate Backup <$EMAIL_FROM>"
        echo "To: <$EMAIL_TO>"
        echo "Subject: $subject"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/html; charset=UTF-8"
        echo
        echo "$html_body"
    ) | if ! curl -s --url "$SMTP_SERVER" --mail-from "$EMAIL_FROM" --mail-rcpt "$EMAIL_TO" --upload-file - >> "$LOG_FILE" 2>&1; then
        log_error "Не удалось отправить email уведомление."
    else
        log_message "Email уведомление успешно отправлено."
    fi
# для использования с аутентификацией. нужное заменить:
# curl -s --url "$SMTP_SERVER" --mail-from "$EMAIL_FROM" --mail-rcpt "$EMAIL_TO" --user "$SMTP_USER:$SMTP_PASS" --upload-file - >> "$LOG_FILE" 2>&1
# для использования без аутентификацией. нужное заменить:
# curl -s --url "$SMTP_SERVER" --mail-from "$EMAIL_FROM" --mail-rcpt "$EMAIL_TO" --upload-file - >> "$LOG_FILE" 2>&1; then   
}




##################################################
# Главная функция
main() {
    # Создаем директории и настраиваем логирование
    mkdir -p "$TODAY_DIR" "$LOG_DIR"
    
    # Регистрируем обработчики сигналов ПЕРВЫМ ДЕЛОМ
    trap cleanup SIGTERM SIGINT SIGHUP
    
    # Перенаправляем весь вывод в лог и на консоль
    exec &> >(tee -a "$LOG_FILE")
    
    log_message "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ ==="

    check_dependencies
    check_free_space

    # --- Создание архивов ---
    archive_accounts
    archive_domains
    archive_other_folders
    check_accounts_archives
    # --- Проверка архивов ---
    validate_all_archives

    # Более надёжная проверка, были ли созданы архивы.
    if ! find "$TODAY_DIR" -maxdepth 1 -type f -name '*.tar.gz' -print -quit | grep -q .; then
        log_error "Ни одного архива не было создано. Процесс прерван."
        send_email "FATAL" "Резервное копирование провалилось: ни одного архива не создано."
        exit 1
    fi
    log_message "Архивы успешно созданы. Всего: $SENT_FILES шт."

    # --- Ротация и загрузка ---
    rotate_by_count "$BACKUP_BASE" "$RETENTION_DAYS"
    upload_to_shara "$BACKUP_BASE" "${SHARA}${SHARA_DIR_DAY}" "Дневные"

    # --- Ежемесячные задачи ---
    if [[ "$(date +%d)" == "01" ]]; then
        monthly_archive
        rotate_by_count "$MONTHLY_BACKUP_DIR" "$MONTHLY_RETENTION"
        upload_to_shara "$MONTHLY_BACKUP_DIR" "${SHARA}${SHARA_DIR_MONTHLY}" "Месячные"
    fi

    # --- Формирование отчёта ---
    local final_status="SUCCESS"
    local final_message="Резервное копирование выполнено успешно."
    if (( ${#ERRORS_IN_RUN[@]} > 0 )); then
        final_status="WARNING"
        final_message="Резервное копирование выполнено с ошибками или предупреждениями."
    fi
    send_email "$final_status" "$final_message"

    rotate_logs
    log_message "=== ЗАВЕРШЕНИЕ РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
}

##################################################
# Запуск
main "$@"
