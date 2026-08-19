#!/bin/bash
# Скрипт развертывания трёх изолированных контейнеров с SSH-доступом (только root)
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

# Генерируем общий root-пароль
PASS_ROOT=$(openssl rand -base64 12)

# --- Создание Dockerfile (Ubuntu) ---
cat > Dockerfile <<'EOF'
FROM ubuntu:22.04

# Установка SSH-сервера
RUN apt-get update && \
    apt-get install -y openssh-server && \
    rm -rf /var/lib/apt/lists/*

# Создаём каталог для работы sshd
RUN mkdir -p /run/sshd

# Настройка SSH (разрешаем парольный вход для root)
RUN ssh-keygen -A && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Копируем скрипт запуска
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
EOF

# --- Создание entrypoint.sh (без изменений) ---
cat > entrypoint.sh <<'EOF'
#!/bin/sh
# Устанавливаем пароль для root
echo "root:${ROOT_PASSWORD}" | chpasswd

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
    local data_dir="/opt/${name}-data"

    mkdir -p "$data_dir"

    local docker_opts="--name $name --cpus $cpu --memory $memory --memory-swap $memory"
    if docker run --rm --storage-opt size=${disk} alpine true 2>/dev/null; then
        docker_opts="$docker_opts --storage-opt size=${disk}"
        echo "  Поддержка storage-opt включена (ограничение диска $disk)"
    else
        echo "  Предупреждение: storage-opt не поддерживается, ограничение диска не будет применено."
    fi

    docker_opts="$docker_opts -v $data_dir:/data -p $ssh_port:22"
    docker_opts="$docker_opts -e ROOT_PASSWORD=$PASS_ROOT"

    docker run -d $docker_opts my-ssh

    echo "  Контейнер $name запущен. SSH порт: $ssh_port"
}

# --- Удаляем старые контейнеры ---
for c in vpn sandbox1 sandbox2; do
    if docker ps -a --format '{{.Names}}' | grep -q "^$c$"; then
        echo "Останавливаем и удаляем существующий контейнер $c..."
        docker stop $c 2>/dev/null || true
        docker rm $c 2>/dev/null || true
    fi
done

# --- Запуск контейнеров ---
echo -e "${GREEN}Запускаем контейнеры...${NC}"

run_container "vpn"       0.2 1g 1g 2222
run_container "sandbox1"  0.4 2g 3g 2223
run_container "sandbox2"  0.4 2g 3g 2224

# --- Определяем внешний IPv4-адрес ---
IP=$(curl -4 -s ifconfig.me || echo "IP_АДРЕС_ХОСТА")

# --- Сохраняем информацию в файл (с паролем) ---
INFO_FILE="/root/container_info.txt"
cat > "$INFO_FILE" <<EOF
Дата развертывания: $(date)
IP-адрес хоста (IPv4): $IP

Доступ по SSH/SFTP (только root):
  VPN:       ssh -p 2222 root@$IP
  Sandbox1:  ssh -p 2223 root@$IP
  Sandbox2:  ssh -p 2224 root@$IP

Root пароль (общий для всех): $PASS_ROOT

Данные контейнеров хранятся в /opt/<имя>-data
==================================================
EOF

# --- Вывод в консоль (без пароля) ---
echo -e "\n${GREEN}✅ Развёртывание завершено!${NC}"
echo "=================================================="
echo "Доступ по SSH/SFTP (только root):"
echo "  VPN:       ssh -p 2222 root@$IP"
echo "  SandBox1:  ssh -p 2223 root@$IP"
echo "  SandBox2:  ssh -p 2224 root@$IP"
echo ""
echo "Root пароль сохранён в файле: $INFO_FILE"
echo "Данные контейнеров хранятся в /opt/<имя>-data"
echo "=================================================="
echo -e "${GREEN}Информация сохранена в файл: $INFO_FILE${NC}"
