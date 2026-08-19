#!/bin/bash
# Скрипт развертывания трёх изолированных контейнеров с SSH-доступом
# Требует прав root и установленного Docker (устанавливается автоматически для Debian/Ubuntu)

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Начинаем установку изолированных контейнеров...${NC}"

# Проверка прав
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# Установка Docker, если отсутствует
if ! command -v docker &> /dev/null; then
    echo "Docker не установлен. Устанавливаем..."
    apt-get update
    apt-get install -y docker.io
    systemctl start docker
    systemctl enable docker
fi

# Директория для сборки образа
BUILD_DIR="/opt/docker-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Генерируем случайные пароли для доступа
PASS_ROOT=$(openssl rand -base64 12)
PASS_VPN=$(openssl rand -base64 12)
PASS_SANDBOX1=$(openssl rand -base64 12)
PASS_SANDBOX2=$(openssl rand -base64 12)

# --- Создание Dockerfile (без nginx и SSL) ---
cat > Dockerfile <<'EOF'
FROM alpine:latest

# Установка только SSH-сервера и необходимых утилит
RUN apk add --no-cache openssh-server

# Настройка SSH (разрешаем парольный вход и root)
RUN ssh-keygen -A && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Создаём пользователя app (для обычного доступа)
RUN adduser -D -h /home/app -s /bin/bash app

# Копируем скрипт запуска
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
EOF

# --- Создание entrypoint.sh (только SSH) ---
cat > entrypoint.sh <<'EOF'
#!/bin/sh
# Устанавливаем пароли из переменных окружения
echo "root:${ROOT_PASSWORD}" | chpasswd
echo "app:${APP_PASSWORD}" | chpasswd

# Запускаем SSH-сервер в foreground
/usr/sbin/sshd -D
EOF
chmod +x entrypoint.sh

# --- Сборка образа ---
echo -e "${GREEN}Сборка образа my-ssh...${NC}"
docker build -t my-ssh .

# --- Функция запуска контейнера ---
run_container() {
    local name=$1
    local cpu=$2
    local memory=$3
    local disk=$4
    local ssh_port=$5
    local app_pass=$6
    local data_dir="/opt/${name}-data"

    mkdir -p "$data_dir"

    # Формируем параметры Docker
    local docker_opts="--name $name --cpus $cpu --memory $memory --memory-swap $memory"
    # Пытаемся применить ограничение диска, если поддерживается
    if docker run --rm --storage-opt size=${disk} alpine true 2>/dev/null; then
        docker_opts="$docker_opts --storage-opt size=${disk}"
        echo "  Поддержка storage-opt включена (ограничение диска $disk)"
    else
        echo "  Предупреждение: storage-opt не поддерживается, ограничение диска не будет применено."
    fi

    docker_opts="$docker_opts -v $data_dir:/data -p $ssh_port:22"
    docker_opts="$docker_opts -e ROOT_PASSWORD=$PASS_ROOT -e APP_PASSWORD=$app_pass"

    # Запускаем контейнер
    docker run -d $docker_opts my-ssh

    echo "  Контейнер $name запущен. SSH порт: $ssh_port, пароль для app: $app_pass"
}

# --- Удаляем старые контейнеры (если есть) ---
for c in vpn sandbox1 sandbox2; do
    if docker ps -a --format '{{.Names}}' | grep -q "^$c$"; then
        echo "Останавливаем и удаляем существующий контейнер $c..."
        docker stop $c 2>/dev/null || true
        docker rm $c 2>/dev/null || true
    fi
done

# --- Запуск контейнеров ---
echo -e "${GREEN}Запускаем контейнеры...${NC}"

run_container "vpn"       0.2 1g 1g 2222 "$PASS_VPN"
run_container "sandbox1"  0.4 2g 3g 2223 "$PASS_SANDBOX1"
run_container "sandbox2"  0.4 2g 3g 2224 "$PASS_SANDBOX2"

# --- Информация о доступе ---
IP=$(curl -s ifconfig.me || echo "IP_АДРЕС_ХОСТА")
echo -e "\n${GREEN}✅ Развёртывание завершено!${NC}"
echo "=================================================="
echo "Доступ по SSH/SFTP (как к отдельным VPS):"
echo "  VPN:       ssh -p 2222 app@$IP    (пароль: $PASS_VPN)"
echo "  Sandbox1:  ssh -p 2223 app@$IP    (пароль: $PASS_SANDBOX1)"
echo "  Sandbox2:  ssh -p 2224 app@$IP    (пароль: $PASS_SANDBOX2)"
echo ""
echo "Root пароль (одинаков для всех): $PASS_ROOT"
echo "  (для входа как root: ssh -p порт root@$IP)"
echo ""
echo "Данные контейнеров хранятся в /opt/<имя>-data"
echo "=================================================="
