#!/bin/bash

# -------------------------------------------------------------------
# CommuniGate Pro Backup Script
# Purpose: Creates daily and monthly backups of CommuniGate Pro data,
#          uploads them to an FTP server, cleans up old backups (local and FTP),
#          and sends email notifications.
# Usage: Configure the variables in "User Configuration" section below,
#        then run the script daily via cron (e.g., `0 2 * * * /path/to/script.sh`).
# Requirements: bash, tar, curl, base64, pigz (optional for faster compression).
# License: MIT (use, modify, and distribute freely with attribution).
# -------------------------------------------------------------------

# -------------------- КОНФИГУРАЦИЯ ПОЛЬЗОВАТЕЛЯ --------------------
# Эти переменные необходимо настроить под ваш сервер.

# BASE_DIR: Путь к директории данных CommuniGate Pro.
# Пример: "/var/CommuniGate"
# Укажите полный путь к директории, где хранятся данные CommuniGate (Accounts, SystemLogs, Settings, Domains).
BASE_DIR="/path/to/CommuniGate"

# BACKUP_BASE: Базовая директория для локальных резервных копий.
# Пример: "/backups/CommuniGate"
# Укажите путь, куда будут сохраняться архивы (должна быть доступна для записи).
BACKUP_BASE="/path/to/backups"

# FTP_SERVER: Адрес FTP-сервера для хранения резервных копий.
# Пример: "ftp.example.com" или "192.168.1.100"
# Укажите домен или IP-адрес вашего FTP-сервера.
FTP_SERVER=""

# FTP_PORT: Порт FTP-сервера.
# Пример: "21" (стандартный порт) или "2121" для нестандартного.
# Укажите порт, если ваш FTP-сервер использует порт, отличный от 21. Оставьте пустым для порта по умолчанию (21).
FTP_PORT="21"

# FTP_USER: Имя пользователя для доступа к FTP.
# Пример: "ftp_user"
# Укажите имя пользователя FTP.
FTP_USER=""

# FTP_PASS: Пароль для доступа к FTP.
# Пример: "your_secure_password"
# Укажите пароль FTP (храните скрипт в безопасном месте).
FTP_PASS=""

# FTP_BASE_DIR: Базовый путь на FTP-сервере для хранения резервных копий.
# Пример: "/backups/CommuniGate"
# Укажите путь на FTP, куда будут загружаться архивы (без конечного слэша).
FTP_BASE_DIR="/backups"

# NOTIFICATION_EMAIL: Email для отправки уведомлений.
# Пример: "admin@example.com"
# Укажите адрес, на который будут приходить отчеты о выполнении.
NOTIFICATION_EMAIL=""

# POSTMASTER_NAME: Email-адрес отправителя уведомлений.
# Пример: "backup@example.com"
# Укажите адрес, от имени которого отправляются письма (обычно совпадает с NOTIFICATION_EMAIL).
POSTMASTER_NAME=""

# SMTP_SERVER: Адрес SMTP-сервера для отправки email.
# Пример: "smtp.example.com" или "127.0.0.1"
# Укажите адрес SMTP-сервера (может быть локальным или внешним).
SMTP_SERVER=""

# MAIN_DOMAIN: Основной домен сервера для именования архива Accounts.
# Пример: "example.com"
# Укажите основной домен, который будет использоваться в имени архива Accounts.
MAIN_DOMAIN="example.com"

# -------------------- СИСТЕМНЫЕ НАСТРОЙКИ --------------------
# Эти переменные обычно не требуют изменений, но могут быть настроены при необходимости.

# TODAY: Текущая дата в формате YYYY-MM-DD (автоматически).
# Используется для именования директорий и архивов.
TODAY=$(date +"%Y-%m-%d")

# TIMESTAMP: Текущее время в формате HHMMSS (автоматически).
# Добавляется к именам архивов для уникальности.
TIMESTAMP=$(date +"%H%M%S")

# DAY_OF_MONTH: День месяца (автоматически).
# Используется для определения, нужно ли создавать месячные архивы (1-е число).
DAY_OF_MONTH=$(date +"%d")

# MONTH: Год и месяц в формате YYYY-MM (автоматически).
# Используется для логирования и именования месячных архивов.
MONTH=$(date +"%Y-%m")

# BACKUP_DIR: Директория для ежедневных архивов.
# Формируется как $BACKUP_BASE/YYYY-MM-DD.
BACKUP_DIR="$BACKUP_BASE/$TODAY"

# MONTHLY_BACKUP_DIR: Директория для месячных архивов.
# Формируется как $BACKUP_BASE/Monthly.
MONTHLY_BACKUP_DIR="$BACKUP_BASE/Monthly"

# LOG_FILE: Путь к файлу лога.
# Хранит подробный отчет о выполнении скрипта.
LOG_FILE="$BACKUP_DIR/backup.log"

# FTP_TARGET_DIR: Путь на FTP для текущей даты.
# Формируется как $FTP_BASE_DIR/YYYY-MM-DD.
FTP_TARGET_DIR="$FTP_BASE_DIR/$TODAY"

# SHOW_LOG: Выводить логи в консоль в реальном времени (true/false).
# Полезно для отладки или мониторинга.
SHOW_LOG=true

# CLEAR_BACKUP_DIR: Очищать $BACKUP_DIR перед новым запуском (true/false).
# Если true, удаляет старые архивы в $BACKUP_DIR перед созданием новых.
CLEAR_BACKUP_DIR=false

# RETENTION_DAYS: Время хранения ежедневных архивов (в днях).
# Архивы старше этого срока удаляются локально и на FTP.
RETENTION_DAYS=7

# MONTHLY_RETENTION: Количество хранимых наборов месячных архивов.
# Оставляет указанное количество последних наборов (по 1-му числу месяца).
MONTHLY_RETENTION=2

# REQUIRED_SPACE: Минимальное свободное место на диске (в МБ).
# Если места меньше, скрипт завершится с ошибкой.
REQUIRED_SPACE=1024

# -------------------- ПРОВЕРКА ЗАВИСИМОСТЕЙ --------------------
# Проверка наличия необходимых утилит
USE_PIGZ=false
for cmd in tar curl base64; do
    command -v "$cmd" >/dev/null || { echo "[$(date)]: Ошибка: Утилита $cmd не найдена" >&2; exit 1; }
done
if command -v pigz >/dev/null; then
    USE_PIGZ=true
    echo "[$(date)]: pigz найден, будет использоваться для сжатия" >&2
else
    echo "[$(date)]: pigz не найден, будет использоваться стандартный gzip" >&2
fi

# Проверка обязательных пользовательских настроек
for var in FTP_SERVER FTP_USER FTP_PASS NOTIFICATION_EMAIL; do
    if [ -z "${!var}" ]; then
        echo "[$(date)]: Ошибка: Переменная $var не задана" >&2
        exit 1
    fi
done

# Формирование FTP URL с учетом порта
if [ -n "$FTP_PORT" ]; then
    FTP_URL="ftp://$FTP_SERVER:$FTP_PORT"
else
    FTP_URL="ftp://$FTP_SERVER"
fi

# -------------------- ПОДГОТОВКА --------------------
# Проверка прав доступа
[ -r "$BASE_DIR" ] || { echo "[$(date)]: Ошибка: Нет прав чтения в $BASE_DIR" >&2; exit 1; }
[ -w "$BACKUP_BASE" ] || { echo "[$(date)]: Ошибка: Нет прав записи в $BACKUP_BASE" >&2; exit 1; }

# Проверка свободного места на диске
FREE_SPACE=$(df -m "$BACKUP_BASE" | tail -1 | awk '{print $4}')
[ "$FREE_SPACE" -lt "$REQUIRED_SPACE" ] && { echo "[$(date)]: Ошибка: Недостаточно места на диске ($FREE_SPACE МБ)" >&2; exit 1; }

# Создание директорий и подготовка лога
mkdir -p "$BACKUP_DIR"
mkdir -p "$MONTHLY_BACKUP_DIR"
if [ "$CLEAR_BACKUP_DIR" = true ]; then
    rm -f "$BACKUP_DIR"/*.tar.gz
    rm -f "$BACKUP_DIR"/*.log
fi
: > "$LOG_FILE"  # Перезаписываем лог
echo "[$(date)]: Новый запуск скрипта резервного копирования CommuniGate" >> "$LOG_FILE"
echo "[$(date)]: Директория $BACKUP_DIR создана" >> "$LOG_FILE"

# Функция логирования
# Записывает сообщение в лог и, при SHOW_LOG=true, выводит в консоль
log() {
    echo "[$(date)]: $1" >> "$LOG_FILE"
    if [ "$SHOW_LOG" = true ]; then
        echo "[$(date)]: $1"
    fi
}

# Функция отправки email
# Отправляет уведомление с логом в качестве вложения
send_email() {
    local message="$1"
    local subject="$2"
    local attach_log="$3"
    local boundary="=====MULTIPART_BOUNDARY_$(date +%s)====="
    local temp_file="/tmp/mail_$(date +%s).eml"

    {
        echo "From: \"Backup Script\" <$POSTMASTER_NAME>"
        echo "To: $NOTIFICATION_EMAIL"
        echo "Subject: $subject"
        echo "Date: $(date -R)"
        echo "Message-ID: <$(date +%s)>"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
        echo ""
        echo "--$boundary"
        echo "Content-Type: text/plain; charset=utf-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        echo -e "$message"
        echo ""
        echo "--$boundary"
        echo "Content-Type: application/octet-stream; name=\"$(basename "$LOG_FILE")\""
        echo "Content-Transfer-Encoding: base64"
        echo "Content-Disposition: attachment; filename=\"$(basename "$LOG_FILE")\""
        echo ""
        base64 "$LOG_FILE"
        echo ""
        echo "--$boundary--"
    } > "$temp_file"

    curl --url "smtp://$SMTP_SERVER" \
         --mail-from "$POSTMASTER_NAME" \
         --mail-rcpt "$NOTIFICATION_EMAIL" \
         --upload-file "$temp_file" >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        log "Критическая ошибка: Не удалось отправить уведомление на $NOTIFICATION_EMAIL"
        rm -f "$temp_file"
        exit 1
    fi
    log "Уведомление отправлено на $NOTIFICATION_EMAIL"
    rm -f "$temp_file"
}

# -------------------- ОЧИСТКА СТАРЫХ АРХИВОВ --------------------
# Удаление локальных папок старше RETENTION_DAYS
log "Очистка локальных архивов старше $RETENTION_DAYS дней..."
find "$BACKUP_BASE" -maxdepth 1 -type d -name "20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]" -mtime +"$RETENTION_DAYS" -exec rm -rf {} + 2>> "$LOG_FILE" && \
    log "Локальные старые архивы удалены" || \
    log "Ошибка при очистке локальных архивов"

# Очистка старых месячных архивов (только 1-го числа)
if [ "$DAY_OF_MONTH" = "01" ]; then
    log "Очистка месячных архивов, оставляем только $MONTHLY_RETENTION последних..."
    find "$MONTHLY_BACKUP_DIR" -type f -name "*.tar.gz" -printf "%T@\t%p\n" | sort -nr | tail -n +$((MONTHLY_RETENTION+1)) | cut -f2- | xargs -I {} rm -f {} 2>> "$LOG_FILE" && \
        log "Старые месячные архивы удалены" || \
        log "Ошибка при очистке месячных архивов"
else
    log "Сегодня не 1-е число, пропуск создания и ротации месячных архивов"
fi

# -------------------- АРХИВАЦИЯ --------------------
log "Начинаем этап архивации..."
cd "$BASE_DIR" || { log "Ошибка: не удалось перейти в $BASE_DIR"; send_email "Ошибка: Не удалось перейти в $BASE_DIR\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true; exit 1; }

# Архив /Accounts
if [ -d "$BASE_DIR/Accounts" ]; then
    ARCHIVE_ACCOUNTS="$BACKUP_DIR/${TODAY}-${TIMESTAMP}_Accounts_${MAIN_DOMAIN}.tar.gz"
    MONTHLY_ARCHIVE_ACCOUNTS="$MONTHLY_BACKUP_DIR/${TODAY}-Monthly_Accounts_${MAIN_DOMAIN}.tar.gz"
    if [ "$USE_PIGZ" = true ]; then
        if tar -cf - Accounts 2>> "$LOG_FILE" | pigz > "$ARCHIVE_ACCOUNTS"; then
            if tar -tzf "$ARCHIVE_ACCOUNTS" >/dev/null 2>> "$LOG_FILE"; then
                log "Архив создан и проверен: $ARCHIVE_ACCOUNTS (с pigz)"
                [ "$DAY_OF_MONTH" = "01" ] && cp "$ARCHIVE_ACCOUNTS" "$MONTHLY_ARCHIVE_ACCOUNTS" && log "Месячный архив создан: $MONTHLY_ARCHIVE_ACCOUNTS"
            else
                log "Ошибка: Архив $ARCHIVE_ACCOUNTS поврежден"
                send_email "Ошибка: Архив $ARCHIVE_ACCOUNTS поврежден\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                exit 1
            fi
        else
            log "Ошибка создания архива Accounts"
            send_email "Ошибка: Не удалось создать архив Accounts\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
            exit 1
        fi
    else
        if tar -czf "$ARCHIVE_ACCOUNTS" Accounts 2>> "$LOG_FILE"; then
            if tar -tzf "$ARCHIVE_ACCOUNTS" >/dev/null 2>> "$LOG_FILE"; then
                log "Архив создан и проверен: $ARCHIVE_ACCOUNTS (с gzip)"
                [ "$DAY_OF_MONTH" = "01" ] && cp "$ARCHIVE_ACCOUNTS" "$MONTHLY_ARCHIVE_ACCOUNTS" && log "Месячный архив создан: $MONTHLY_ARCHIVE_ACCOUNTS"
            else
                log "Ошибка: Архив $ARCHIVE_ACCOUNTS поврежден"
                send_email "Ошибка: Архив $ARCHIVE_ACCOUNTS поврежден\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                exit 1
            fi
        else
            log "Ошибка создания архива Accounts"
            send_email "Ошибка: Не удалось создать архив Accounts\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
            exit 1
        fi
    fi
else
    log "Директория $BASE_DIR/Accounts не найдена"
fi

# Архив /SystemLogs
if [ -d "$BASE_DIR/SystemLogs" ]; then
    ARCHIVE_LOGS="$BACKUP_DIR/${TODAY}-${TIMESTAMP}_SystemLogs.tar.gz"
    MONTHLY_ARCHIVE_LOGS="$MONTHLY_BACKUP_DIR/${TODAY}-Monthly_SystemLogs.tar.gz"
    if [ "$USE_PIGZ" = true ]; then
        if tar -cf - SystemLogs 2>> "$LOG_FILE" | pigz > "$ARCHIVE_LOGS"; then
            if tar -tzf "$ARCHIVE_LOGS" >/dev/null 2>> "$LOG_FILE"; then
                log "Архив создан и проверен: $ARCHIVE_LOGS (с pigz)"
                [ "$DAY_OF_MONTH" = "01" ] && cp "$ARCHIVE_LOGS" "$MONTHLY_ARCHIVE_LOGS" && log "Месячный архив создан: $MONTHLY_ARCHIVE_LOGS"
            else
                log "Ошибка: Архив $ARCHIVE_LOGS поврежден"
                send_email "Ошибка: Архив $ARCHIVE_LOGS поврежден\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                exit 1
            fi
        else
            log "Ошибка создания архива SystemLogs"
            send_email "Ошибка: Не удалось создать архив SystemLogs\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
            exit 1
        fi
    else
        if tar -czf "$ARCHIVE_LOGS" SystemLogs 2>> "$LOG_FILE"; then
            if tar -tzf "$ARCHIVE_LOGS" >/dev/null 2>> "$LOG_FILE"; then
                log "Архив создан и проверен: $ARCHIVE_LOGS (с gzip)"
                [ "$DAY_OF_MONTH" = "01" ] && cp "$ARCHIVE_LOGS" "$MONTHLY_ARCHIVE_LOGS" && log "Месячный архив создан: $MONTHLY_ARCHIVE_LOGS"
            else
                log "Ошибка: Архив $ARCHIVE_LOGS поврежден"
                send_email "Ошибка: Архив $ARCHIVE_LOGS поврежден\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                exit 1
            fi
        else
            log "Ошибка создания архива SystemLogs"
            send_email "Ошибка: Не удалось создать архив SystemLogs\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
            exit 1
        fi
    fi
fi

# Архив /Settings
SETTINGS_DIRS=(CGPClamAV Directory Settings Submitted)
SETTINGS_TO_ARCHIVE=()
for dir in "${SETTINGS_DIRS[@]}"; do
    [ -d "$dir" ] && SETTINGS_TO_ARCHIVE+=("$dir")
done
if [ ${#SETTINGS_TO_ARCHIVE[@]} -gt 0 ]; then
    ARCHIVE_SETTINGS="$BACKUP_DIR/${TODAY}-${TIMESTAMP}_Settings.tar.gz"
    MONTHLY_ARCHIVE_SETTINGS="$MONTHLY_BACKUP_DIR/${TODAY}-Monthly_Settings.tar.gz"
    if [ "$USE_PIGZ" = true ]; then
        if tar -cf - "${SETTINGS_TO_ARCHIVE[@]}" 2>> "$LOG_FILE" | pigz > "$ARCHIVE_SETTINGS"; then
            if tar -tzf "$ARCHIVE_SETTINGS" >/dev/null 2>> "$LOG_FILE"; then
                log "Архив создан и проверен: $ARCHIVE_SETTINGS (с pigz)"
                [ "$DAY_OF_MONTH" = "01" ] && cp "$ARCHIVE_SETTINGS" "$MONTHLY_ARCHIVE_SETTINGS" && log "Месячный архив создан: $MONTHLY_ARCHIVE_SETTINGS"
            else
                log "Ошибка: Архив $ARCHIVE_SETTINGS поврежден"
                send_email "Ошибка: Архив $ARCHIVE_SETTINGS поврежден\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                exit 1
            fi
        else
            log "Ошибка создания архива Settings"
            send_email "Ошибка: Не удалось создать архив Settings\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
            exit 1
        fi
    else
        if tar -czf "$ARCHIVE_SETTINGS" "${SETTINGS_TO_ARCHIVE[@]}" 2>> "$LOG_FILE"; then
            if tar -tzf "$ARCHIVE_SETTINGS" >/dev/null 2>> "$LOG_FILE"; then
                log "Архив создан и проверен: $ARCHIVE_SETTINGS (с gzip)"
                [ "$DAY_OF_MONTH" = "01" ] && cp "$ARCHIVE_SETTINGS" "$MONTHLY_ARCHIVE_SETTINGS" && log "Месячный архив создан: $MONTHLY_ARCHIVE_SETTINGS"
            else
                log "Ошибка: Архив $ARCHIVE_SETTINGS поврежден"
                send_email "Ошибка: Архив $ARCHIVE_SETTINGS поврежден\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                exit 1
            fi
        else
            log "Ошибка создания архива Settings"
            send_email "Ошибка: Не удалось создать архив Settings\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
            exit 1
        fi
    fi
else
    log "Ни одна из директорий ${SETTINGS_DIRS[*]} не найдена"
fi

# Архивы по доменам
if [ -d "$BASE_DIR/Domains" ]; then
    shopt -s nullglob
    for domain in "$BASE_DIR"/Domains/*; do
        [ -d "$domain" ] || continue
        [ "$(ls -A "$domain")" ] || { log "Пропущен пустой домен: $(basename "$domain")"; continue; }
        DOMAIN_NAME=$(basename "$domain")
        ARCHIVE_DOMAIN="$BACKUP_DIR/${TODAY}-${TIMESTAMP}_Domains-${DOMAIN_NAME}.tar.gz"
        MONTHLY_ARCHIVE_DOMAIN="$MONTHLY_BACKUP_DIR/${TODAY}-Monthly_Domains-${DOMAIN_NAME}.tar.gz"
        if [ "$USE_PIGZ" = true ]; then
            if tar -cf - -C "$BASE_DIR/Domains" "$DOMAIN_NAME" 2>> "$LOG_FILE" | pigz > "$ARCHIVE_DOMAIN"; then
                if tar -tzf "$ARCHIVE_DOMAIN" >/dev/null 2>> "$LOG_FILE"; then
                    log "Архив создан и проверен: $ARCHIVE_DOMAIN (с pigz)"
                    [ "$DAY_OF_MONTH" = "01" ] && cp "$ARCHIVE_DOMAIN" "$MONTHLY_ARCHIVE_DOMAIN" && log "Месячный архив создан: $MONTHLY_ARCHIVE_DOMAIN"
                else
                    log "Ошибка: Архив $ARCHIVE_DOMAIN поврежден"
                    send_email "Ошибка: Архив $ARCHIVE_DOMAIN поврежден\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                    exit 1
                fi
            else
                log "Ошибка архивации домена: $DOMAIN_NAME"
                send_email "Ошибка: Не удалось создать архив домена $DOMAIN_NAME\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                exit 1
            fi
        else
            if tar -czf "$ARCHIVE_DOMAIN" -C "$BASE_DIR/Domains" "$DOMAIN_NAME" 2>> "$LOG_FILE"; then
                if tar -tzf "$ARCHIVE_DOMAIN" >/dev/null 2>> "$LOG_FILE"; then
                    log "Архив создан и проверен: $ARCHIVE_DOMAIN (с gzip)"
                    [ "$DAY_OF_MONTH" = "01" ] && cp "$ARCHIVE_DOMAIN" "$MONTHLY_ARCHIVE_DOMAIN" && log "Месячный архив создан: $MONTHLY_ARCHIVE_DOMAIN"
                else
                    log "Ошибка: Архив $ARCHIVE_DOMAIN поврежден"
                    send_email "Ошибка: Архив $ARCHIVE_DOMAIN поврежден\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                    exit 1
                fi
            else
                log "Ошибка архивации домена: $DOMAIN_NAME"
                send_email "Ошибка: Не удалось создать архив домена $DOMAIN_NAME\nСм. лог файл." "Ошибка резервного копирования CommuniGate $TODAY" true
                exit 1
            fi
        fi
    done
    shopt -u nullglob
fi

log "Этап архивации завершён"

# -------------------- FTP ОТПРАВКА --------------------
FTP_FAILED=false
log "Проверка доступности FTP-сервера..."
FTP_TEST_FILE="test_ftp_connection.txt"
echo "Test $(date)" > "$BACKUP_DIR/$FTP_TEST_FILE"

curl --connect-timeout 30 --max-time 600 --ftp-create-dirs -T "$BACKUP_DIR/$FTP_TEST_FILE" \
     "$FTP_URL$FTP_TARGET_DIR/$FTP_TEST_FILE" \
     --user "$FTP_USER:$FTP_PASS" --verbose 2>> "$LOG_FILE"

if [ $? -eq 0 ]; then
    log "FTP доступен. Отправка архивов..."
    for file in "$BACKUP_DIR"/*.tar.gz; do
        curl --connect-timeout 30 --max-time 600 --ftp-create-dirs -T "$file" \
             "$FTP_URL$FTP_TARGET_DIR/$(basename "$file")" \
             --user "$FTP_USER:$FTP_PASS" --verbose 2>> "$LOG_FILE"
        if [ $? -eq 0 ]; then
            log "Отправлен на FTP: $(basename "$file")"
        else
            log "Ошибка отправки файла на FTP: $(basename "$file")"
            FTP_FAILED=true
        fi
    done
else
    log "Ошибка подключения к FTP серверу"
    FTP_FAILED=true
fi

# Удаление тестового файла с FTP
curl --connect-timeout 30 --max-time 600 -Q "DELE $FTP_TARGET_DIR/$FTP_TEST_FILE" \
     "$FTP_URL$FTP_TARGET_DIR/" \
     --user "$FTP_USER:$FTP_PASS" --verbose 2>> "$LOG_FILE" && \
    log "Тестовый файл $FTP_TEST_FILE удален с FTP" || \
    log "Ошибка удаления тестового файла $FTP_TEST_FILE с FTP"

rm -f "$BACKUP_DIR/$FTP_TEST_FILE"

# Отправка лога на FTP
LOG_TEMP="/tmp/backup.log.$(date +%s)"
cp "$LOG_FILE" "$LOG_TEMP"
curl --connect-timeout 30 --max-time 600 --ftp-create-dirs -T "$LOG_TEMP" \
     "$FTP_URL$FTP_TARGET_DIR/$(basename "$LOG_FILE")" \
     --user "$FTP_USER:$FTP_PASS" --verbose 2>> "$LOG_FILE"
if [ $? -eq 0 ]; then
    log "Отправлен на FTP: $(basename "$LOG_FILE")"
else
    log "Ошибка отправки файла на FTP: $(basename "$LOG_FILE")"
    FTP_FAILED=true
fi
rm -f "$LOG_TEMP"

# Очистка старых папок на FTP
log "Очистка старых папок на FTP старше $RETENTION_DAYS дней..."
FTP_LIST=$(curl --connect-timeout 30 --max-time 600 --list-only \
     "$FTP_URL$FTP_BASE_DIR/" \
     --user "$FTP_USER:$FTP_PASS" 2>> "$LOG_FILE" | grep -E '^[0-9]{4}-[0-1][0-9]-[0-3][0-9]$')
log "Найдены FTP папки: ${FTP_LIST:-<пусто>}"
if [ -z "$FTP_LIST" ]; then
    log "Нет папок для удаления на FTP"
else
    DELETED=false
    for dir in $FTP_LIST; do
        dir_date=$(date -d "$dir" +%s 2>/dev/null)
        current_date=$(date +%s)
        if [ $(( (current_date - dir_date) / 86400 )) -gt $RETENTION_DAYS ]; then
            log "Попытка удалить папку $FTP_BASE_DIR/$dir..."
            curl --connect-timeout 30 --max-time 600 -Q "RMD $FTP_BASE_DIR/$dir" \
                 "$FTP_URL$FTP_BASE_DIR/" \
                 --user "$FTP_USER:$FTP_PASS" --verbose 2>> "$LOG_FILE" && \
                log "Папка $FTP_BASE_DIR/$dir удалена с FTP" || \
                log "Ошибка удаления папки $FTP_BASE_DIR/$dir с FTP"
            DELETED=true
        fi
    done
    if [ "$DELETED" = false ]; then
        log "Нет папок старше $RETENTION_DAYS дней для удаления"
    fi
fi

# -------------------- EMAIL УВЕДОМЛЕНИЕ --------------------
log "Отправка уведомления на почту..."
message="Резервное копирование завершено.\nДата: $TODAY\nВремя: $TIMESTAMP\nКаталог: $BACKUP_DIR\nСвободное место на диске: $FREE_SPACE МБ"
[ "$FTP_FAILED" = true ] && message+="\n\n⚠️ Отправка на FTP не удалась. См. лог файл."

send_email "$message" "Резервное копирование CommuniGate $TODAY" true

log "Скрипт завершён."
exit 0
