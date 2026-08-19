#!/bin/bash
# Скрипт развертывания трёх изолированных контейнеров с SSH-доступом (только root)
# Версия с поддержкой systemd для VPN и исправленными ошибками iptables/ip_forward

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Начинаем установку изолированных контейнеров...${NC}"

# Проверка root-прав
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

# Генерация общего пароля root
PASS_ROOT=$(openssl rand -base64 12)

# --- Dockerfile (Ubuntu + systemd + iptables-legacy + SSH) ---
cat > Dockerfile <<'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Установка необходимых пакетов
RUN apt-get update && \
    apt-get install -y openssh-server systemd systemd-sysv iptables curl wget sudo && \
    rm -rf /var/lib/apt/lists/*

# Настройка SSH (разрешаем root-логин с паролем)
RUN ssh-keygen -A && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Переключение iptables на legacy (для совместимости со старыми скриптами)
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy || true && \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

# Включаем SSH-сервис для systemd (пригодится для VPN-контейнера)
RUN systemctl enable ssh || true

# Копируем и настраиваем entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
EOF

# --- entrypoint.sh (выбор режима: systemd или только sshd) ---
cat > entrypoint.sh <<'EOF'
#!/bin/bash
# Устанавливаем пароль root из переменной окружения
echo "root:${ROOT_PASSWORD}" | chpasswd

if [ "$START_INIT" = "1" ]; then
    # Запуск systemd как PID 1 (требует --privileged и монтирования /sys/fs/cgroup)
    exec /sbin/init
else
    # Лёгкий режим: только SSH-демон
    exec /usr/sbin/sshd -D
fi
EOF
chmod +x entrypoint.sh

echo -e "${GREEN}Сборка образа my-ssh...${NC}"
docker build -t my-ssh .

# --- Функция запуска контейнера с дополнительными опциями ---
run_container() {
    local name=$1
    local cpu=$2
    local memory=$3
    local disk=$4
    local ssh_port=$5
    local extra_opts=$6   # дополнительные параметры для docker run
    local start_init=$7   # 1 – запускать systemd, 0 – только sshd
    local data_dir="/opt/${name}-data"

    mkdir -p "$data_dir"

    local docker_opts="--name $name --cpus $cpu --memory $memory --memory-swap $memory"

    # Проверяем поддержку storage-opt (ограничение диска)
    if docker run --rm --storage-opt size=${disk} alpine true 2>/dev/null; then
        docker_opts="$docker_opts --storage-opt size=${disk}"
        echo "  Поддержка storage-opt включена (ограничение диска $disk)"
    else
        echo "  Предупреждение: storage-opt не поддерживается, ограничение диска не будет применено."
    fi

    docker_opts="$docker_opts -v $data_dir:/data -p $ssh_port:22"
    docker_opts="$docker_opts -e ROOT_PASSWORD=$PASS_ROOT"

    if [ "$start_init" = "1" ]; then
        docker_opts="$docker_opts -e START_INIT=1"
    fi

    docker_opts="$docker_opts $extra_opts"

    docker run -d $docker_opts my-ssh

    echo "  Контейнер $name запущен. SSH порт: $ssh_port"
}

# --- Удаляем старые контейнеры (если есть) ---
for c in vpn sandbox1 sandbox2; do
    if docker ps -a --format '{{.Names}}' | grep -q "^$c$"; then
        echo "Останавливаем и удаляем существующий контейнер $c..."
        docker stop $c 2>/dev/null || true
        docker rm $c 2>/dev/null || true
    fi
done

echo -e "${GREEN}Запускаем контейнеры...${NC}"

# VPN-контейнер – с привилегиями, systemd, включённым форвардингом и cgroup
run_container "vpn" 0.2 1g 1g 2222 \
    "--privileged --volume /sys/fs/cgroup:/sys/fs/cgroup:rw --cap-add=ALL --sysctl net.ipv4.ip_forward=1" \
    1

# Песочницы – без systemd, обычные права
run_container "sandbox1" 0.4 2g 3g 2223 "" 0
run_container "sandbox2" 0.4 2g 3g 2224 "" 0

# Определяем внешний IPv4-адрес
IP=$(curl -4 -s ifconfig.me || echo "IP_АДРЕС_ХОСТА")

# --- Сохраняем информацию (с паролем) ---
INFO_FILE="/root/container_info.txt"
cat > "$INFO_FILE" <<EOF
Дата развертывания: $(date)
IP-адрес хоста (IPv4): $IP

Доступ по SSH/SFTP (только root):
  VPN:       ssh -p 2222 root@$IP    (пароль: $PASS_ROOT)
  Sandbox1:  ssh -p 2223 root@$IP    (пароль: $PASS_ROOT)
  Sandbox2:  ssh -p 2224 root@$IP    (пароль: $PASS_ROOT)

Root пароль (общий для всех): $PASS_ROOT

Данные контейнеров хранятся в /opt/<имя>-data
==================================================
EOF

# --- Вывод в консоль ---
echo -e "\n${GREEN}✅ Развёртывание завершено!${NC}"
echo "=================================================="
echo "Доступ по SSH/SFTP (только root):"
echo "  VPN:       ssh -p 2222 root@$IP"
echo "  Sandbox1:  ssh -p 2223 root@$IP"
echo "  Sandbox2:  ssh -p 2224 root@$IP"
echo ""
echo "Root пароль сохранён в файле: $INFO_FILE"
echo "Данные контейнеров хранятся в /opt/<имя>-data"
echo "=================================================="
echo -e "${GREEN}Информация сохранена в файл: $INFO_FILE${NC}"
