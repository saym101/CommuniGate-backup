# CommuniGate Pro Backup Script

![Version](https://img.shields.io/badge/version-4.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Debian%2FUbuntu-orange)
![Shell](https://img.shields.io/badge/shell-bash-lightgrey)

Bash-скрипт для резервного копирования данных **CommuniGate Pro** на Linux-сервере.

Скрипт создаёт ежедневные архивы локально, при необходимости создаёт месячную копию, дополнительно переносит архивы в указанное хранилище и отправляет email-отчёт.

## Что делает скрипт

1. Создаёт локальные архивы в:

   ```text
   /backups/CommuniGate/Day/YYYY-MM-DD
   ```

2. Первого числа месяца или при запуске с ключом `--monthly` создаёт месячную копию в:

   ```text
   /backups/CommuniGate/Monthly/YYYY-MM-DD
   ```

3. Дополнительно копирует архивы в удалённое или внешнее хранилище, указанное в переменной:

   ```bash
   REMOTE_BACKUP_ROOT="/mnt/communigate_backup"
   ```

4. Отправляет HTML-отчёт на email через локальный SMTP:

   ```bash
   SMTP_SERVER="smtp://127.0.0.1:25"
   ```

SMTP-авторизация в скрипте не используется. Скрипт рассчитан на запуск локально на сервере, где работает CommuniGate Pro, Postfix, Exim или другой локальный SMTP-сервис.

---

## Возможности

- Архивация основных аккаунтов из `Accounts`.
- Архивация доменных аккаунтов из `Domains`.
- Архивация системных папок:
  - `Settings`
  - `Directory`
  - `SystemLogs`
  - `Submitted`
- Ежедневные локальные архивы.
- Месячные архивы первого числа месяца.
- Принудительное создание месячной копии через `--monthly`.
- Дополнительное копирование в любое доступное хранилище:
  - NFS
  - Samba/CIFS
  - rclone mount
  - sshfs
  - внешний диск
  - обычная локальная папка
- Проверка свободного места локально и в дополнительном хранилище.
- Проверка marker-файла, чтобы не писать архивы не туда.
- Защита от параллельного запуска через `flock`.
- Поддержка `dry-run`.
- Email-отчёт через локальный SMTP без логина и пароля.
- Ротация локальных и remote-копий.
- Логирование всех важных операций.

---

## Требования

### ОС

Рекомендуется:

```text
Debian 12
Ubuntu Server 22.04/24.04
```

Скрипт должен запускаться от `root`.

### Пакеты

Нужные пакеты:

```bash
apt update
apt install -y pigz curl rsync tar bc util-linux
```

Используемые команды:

```text
bash
pigz
curl
rsync
tar
bc
flock
mountpoint
df
awk
find
sort
xargs
mktemp
sed
stat
basename
chmod
mkdir
rm
mv
tee
```

---

## Установка

Скопируйте скрипт на сервер:

```bash
install -m 700 communigate-backup.sh /usr/local/sbin/communigate-backup.sh
```

Или вручную:

```bash
cp communigate-backup.sh /usr/local/sbin/communigate-backup.sh
chmod 700 /usr/local/sbin/communigate-backup.sh
```

Проверка синтаксиса:

```bash
bash -n /usr/local/sbin/communigate-backup.sh
```

Проверка ShellCheck:

```bash
shellcheck /usr/local/sbin/communigate-backup.sh
```

---

## Основные настройки

Настройки находятся в верхней части скрипта.

### Пути CommuniGate Pro

```bash
BASE_DIR="/var/CommuniGate"
DIR_ACCOUNTS="$BASE_DIR/Accounts"
DOMAINS_DIR="$BASE_DIR/Domains"
```

Обычно для Debian это:

```text
/var/CommuniGate
```

### Локальные бэкапы

```bash
LOCAL_BACKUP_ROOT="/backups/CommuniGate"
LOCAL_DAY_BASE="$LOCAL_BACKUP_ROOT/Day"
LOCAL_MONTHLY_BASE="$LOCAL_BACKUP_ROOT/Monthly"
LOG_DIR="$LOCAL_BACKUP_ROOT/Logs"
```

Итоговая структура:

```text
/backups/CommuniGate/
├── Day/
│   └── YYYY-MM-DD/
├── Monthly/
│   └── YYYY-MM-DD/
└── Logs/
```

### Дополнительное хранилище

Скрипт не знает и не должен знать, чем является дополнительное хранилище. Это может быть NFS, Samba/CIFS, rclone mount, sshfs, внешний диск или обычная локальная папка.

Главная переменная:

```bash
REMOTE_BACKUP_ROOT="/mnt/communigate_backup"
```

Структура внутри дополнительного хранилища:

```text
/mnt/communigate_backup/
└── CommuniGate/
    ├── Day/
    ├── Monthly/
    └── Logs/
```

### Проверка mountpoint

По умолчанию рекомендуется требовать, чтобы `REMOTE_BACKUP_ROOT` был точкой монтирования:

```bash
REMOTE_REQUIRE_MOUNTPOINT=true
```

Это защищает от ситуации, когда NFS/Samba/rclone не смонтировались, а скрипт начал писать архивы в пустую локальную папку `/mnt/...`.

Если вы используете обычную локальную папку, укажите:

```bash
REMOTE_REQUIRE_MOUNTPOINT=false
```

### Marker-файл

Marker-файл защищает от записи не в то хранилище:

```bash
REMOTE_REQUIRE_MARKER=true
REMOTE_MARKER_FILE="$REMOTE_BACKUP_ROOT/backup_marker_do_not_delete"
```

Создать marker-файл:

```bash
touch /mnt/communigate_backup/backup_marker_do_not_delete
```

Если marker-файл не нужен:

```bash
REMOTE_REQUIRE_MARKER=false
```

---

## Настройки хранения

```bash
LOCAL_DAILY_RETENTION_DAYS=4
REMOTE_DAILY_RETENTION_DAYS=14
MONTHLY_RETENTION=3
LOG_RETENTION_COUNT=16
```

Значения означают:

- `LOCAL_DAILY_RETENTION_DAYS` — сколько дней хранить локальные дневные копии.
- `REMOTE_DAILY_RETENTION_DAYS` — сколько дней хранить дневные копии в дополнительном хранилище.
- `MONTHLY_RETENTION` — сколько последних месячных наборов хранить.
- `LOG_RETENTION_COUNT` — сколько последних логов хранить.

---

## Настройки свободного места

```bash
REQUIRED_SPACE_LOCAL=2000
REQUIRED_SPACE_REMOTE=5000
```

Значения указаны в мегабайтах.

Если свободного места локально меньше `REQUIRED_SPACE_LOCAL`, скрипт завершится с ошибкой.

Если свободного места в дополнительном хранилище меньше `REQUIRED_SPACE_REMOTE`, скрипт продолжит работу, но итоговый статус будет `CRITICAL`.

---

## Настройки email

Скрипт отправляет письмо через локальный SMTP без авторизации:

```bash
MAIN_DOMAIN="example.com"
EMAIL_TO="admin@example.com"
EMAIL_FROM="backup@example.com"
SMTP_SERVER="smtp://127.0.0.1:25"
```

В скрипте специально нет:

```bash
EMAIL_LOGIN
EMAIL_PASS
--user
```

Проверка локальной отправки вручную:

```bash
cat > /tmp/test-backup-mail.txt <<'MAIL'
From: <backup@example.com>
To: <admin@example.com>
Subject: Test backup mail
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

Тест отправки через локальный SMTP без авторизации.
MAIL

curl -v \
  --url smtp://127.0.0.1:25 \
  --mail-from backup@example.com \
  --mail-rcpt admin@example.com \
  --upload-file /tmp/test-backup-mail.txt
```

---

## Использование

### Обычный запуск

```bash
/usr/local/sbin/communigate-backup.sh
```

### Проверка без создания архивов и копирования

```bash
/usr/local/sbin/communigate-backup.sh --dry-run --no-email
```

### Принудительное создание месячной копии

```bash
/usr/local/sbin/communigate-backup.sh --monthly
```

### Запуск без email-уведомления

```bash
/usr/local/sbin/communigate-backup.sh --no-email
```

### Справка

```bash
/usr/local/sbin/communigate-backup.sh --help
```

---

## Настройка cron

Откройте системный cron:

```bash
mcedit /etc/crontab
```

Пример ежедневного запуска в 02:30:

```cron
30 2 * * * root /usr/local/sbin/communigate-backup.sh
```

---

## Пример настройки NFS

Установка клиента:

```bash
apt update
apt install -y nfs-common
```

Создание точки монтирования:

```bash
mkdir -p /mnt/communigate_backup
```

Пример строки `/etc/fstab`:

```fstab
192.168.1.10:/backup/communigate /mnt/communigate_backup nfs defaults,_netdev,nofail 0 0
```

Монтирование:

```bash
mount /mnt/communigate_backup
touch /mnt/communigate_backup/backup_marker_do_not_delete
```

Настройки в скрипте:

```bash
REMOTE_BACKUP_ROOT="/mnt/communigate_backup"
REMOTE_REQUIRE_MOUNTPOINT=true
REMOTE_REQUIRE_MARKER=true
```

---

## Пример настройки Samba/CIFS

Установка клиента:

```bash
apt update
apt install -y cifs-utils
```

Файл учётных данных:

```bash
mcedit /root/.smb-communigate-backup
```

Пример:

```ini
username=backup_user
password=backup_password
domain=WORKGROUP
```

Права:

```bash
chmod 600 /root/.smb-communigate-backup
```

Создание точки монтирования:

```bash
mkdir -p /mnt/communigate_backup
```

Пример строки `/etc/fstab`:

```fstab
//192.168.1.10/backup /mnt/communigate_backup cifs credentials=/root/.smb-communigate-backup,iocharset=utf8,vers=3.0,_netdev,nofail 0 0
```

Монтирование:

```bash
mount /mnt/communigate_backup
touch /mnt/communigate_backup/backup_marker_do_not_delete
```

Настройки в скрипте:

```bash
REMOTE_BACKUP_ROOT="/mnt/communigate_backup"
REMOTE_REQUIRE_MOUNTPOINT=true
REMOTE_REQUIRE_MARKER=true
```

---

## Пример настройки rclone mount

Скрипт бэкапа не запускает `rclone mount` самостоятельно. Настройте rclone mount отдельно, например через systemd.

Итоговая точка должна быть доступна как обычный каталог:

```text
/mnt/communigate_backup
```

Проверка:

```bash
mountpoint /mnt/communigate_backup
touch /mnt/communigate_backup/backup_marker_do_not_delete
```

Настройки в скрипте:

```bash
REMOTE_BACKUP_ROOT="/mnt/communigate_backup"
REMOTE_REQUIRE_MOUNTPOINT=true
REMOTE_REQUIRE_MARKER=true
```

---

## Структура архивов

### Локально

```text
/backups/CommuniGate/
├── Day/
│   └── YYYY-MM-DD/
│       ├── accounts/
│       ├── domains/
│       └── system/
├── Monthly/
│   └── YYYY-MM-DD/
└── Logs/
```

### В дополнительном хранилище

```text
/mnt/communigate_backup/
└── CommuniGate/
    ├── Day/
    │   └── YYYY-MM-DD/
    ├── Monthly/
    │   └── YYYY-MM-DD/
    └── Logs/
```

---

## Логи

Логи хранятся локально:

```text
/backups/CommuniGate/Logs/
```

Также текущий лог копируется в дополнительное хранилище:

```text
/mnt/communigate_backup/CommuniGate/Logs/
```

Посмотреть последний лог:

```bash
ls -1t /backups/CommuniGate/Logs/backup_*.log | head -n 1
```

Пример просмотра:

```bash
tail -n 100 /backups/CommuniGate/Logs/backup_YYYY-MM-DD-HHMMSS.log
```

---

## Устранение неполадок

### Дополнительное хранилище недоступно

Проверьте:

```bash
mountpoint /mnt/communigate_backup
ls -la /mnt/communigate_backup
ls -la /mnt/communigate_backup/backup_marker_do_not_delete
```

Если это обычная локальная папка, установите:

```bash
REMOTE_REQUIRE_MOUNTPOINT=false
```

### Marker-файл не найден

Создайте marker-файл:

```bash
touch /mnt/communigate_backup/backup_marker_do_not_delete
```

### Email не приходит

Проверьте локальную отправку:

```bash
curl -v \
  --url smtp://127.0.0.1:25 \
  --mail-from backup@example.com \
  --mail-rcpt admin@example.com \
  --upload-file /tmp/test-backup-mail.txt
```

Проверьте очередь и логи вашего почтового сервера.

### Недостаточно места

Проверьте:

```bash
df -h /backups/CommuniGate
df -h /mnt/communigate_backup
```

Измените лимиты:

```bash
REQUIRED_SPACE_LOCAL=2000
REQUIRED_SPACE_REMOTE=5000
```

### Архивы не создаются 1 числа

Проверьте дату сервера:

```bash
date
```

Принудительно проверьте monthly-режим:

```bash
/usr/local/sbin/communigate-backup.sh --monthly --no-email
```

---

## Безопасность перед публикацией на GitHub

Перед публикацией проверьте, что в скрипте нет реальных доменов, email-адресов, паролей и внутренних IP:

```bash
grep -nE 'stpserver|clubideal|alexs|statmon|EMAIL_PASS|EMAIL_LOGIN|--user|[0-9]{1,3}(\.[0-9]{1,3}){3}' communigate-backup.sh
```

В публичной версии используйте:

```bash
MAIN_DOMAIN="example.com"
EMAIL_TO="admin@example.com"
EMAIL_FROM="backup@example.com"
REMOTE_BACKUP_ROOT="/mnt/communigate_backup"
```

Не публикуйте:

```text
rclone.conf
*.log
*.tar.gz
*.conf с реальными доступами
ключи
пароли
```

---

## Рекомендуемый `.gitignore`

```gitignore
# Реальные конфиги и секреты
*.conf
.env
rclone.conf
*.key
*.pem
id_rsa
id_ed25519

# Логи
*.log
logs/
Logs/

# Архивы и бэкапы
*.tar
*.tar.gz
*.tgz
*.zip
*.7z
*.bak
backups/

# Временные файлы
*.tmp
*.swp
*~
```

---

## Лицензия

Проект распространяется под лицензией MIT.

---

## Рекомендуемые права

Скрипт:

```bash
chmod 700 /usr/local/sbin/communigate-backup.sh
```

Если используется отдельный конфиг с реальными настройками:

```bash
chmod 600 /etc/communigate-backup.conf
```
