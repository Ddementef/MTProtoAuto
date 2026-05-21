#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR/mtg-data"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CONFIG_FILE="$INSTALL_DIR/config.toml"
FAKE_TLS_DOMAIN="ya.ru"
PORT="443"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

get_ip() {
    curl -s ifconfig.me
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Запустите скрипт от root.${NC}"
        exit 1
    fi
}

require_install() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}Прокси не установлен. Выберите пункт 1.${NC}"
        exit 1
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        echo -e "${GREEN}Docker уже установлен.${NC}"
        return
    fi
    echo -e "${CYAN}Устанавливаю Docker...${NC}"
    apt-get update -q
    apt-get install -y -q ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}Docker установлен.${NC}"
}

install_proxy() {
    require_root

    if [[ -f "$COMPOSE_FILE" ]]; then
        echo -e "${YELLOW}Прокси уже установлен.${NC}"
        show_link
        return
    fi

    install_docker

    echo -e "${CYAN}Генерирую секрет Fake TLS для домена $FAKE_TLS_DOMAIN...${NC}"
    SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$FAKE_TLS_DOMAIN")
    echo -e "${GREEN}Секрет: $SECRET${NC}"

    mkdir -p "$INSTALL_DIR"

    cat > "$CONFIG_FILE" << EOF
secret = "$SECRET"
bind-to = "0.0.0.0:$PORT"
EOF

    cat > "$COMPOSE_FILE" << EOF
services:
  mtg:
    image: nineseconds/mtg:2
    container_name: mtg
    restart: unless-stopped
    ports:
      - "$PORT:$PORT"
    volumes:
      - $CONFIG_FILE:/config.toml:ro
    command: run /config.toml
EOF

    cd "$INSTALL_DIR"
    docker compose up -d

    IP=$(get_ip)
    echo ""
    echo -e "${GREEN}Прокси запущен!${NC}"
    print_link "$IP" "$SECRET"
}

show_status() {
    require_install
    echo -e "${CYAN}Статус контейнера:${NC}"
    docker ps -a --filter name=mtg --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo -e "${CYAN}Последние 20 строк логов:${NC}"
    docker logs mtg --tail 20
}

print_link() {
    local url="tg://proxy?server=$1&port=$PORT&secret=$2"
    echo ""
    echo -e "${CYAN}Ссылка для Telegram:${NC}"
    printf "\e]8;;%s\a%s\e]8;;\a\n" "$url" "$url"
}

show_link() {
    require_install
    SECRET=$(grep 'secret' "$CONFIG_FILE" | cut -d'"' -f2)
    IP=$(get_ip)
    print_link "$IP" "$SECRET"
}

update_proxy() {
    require_root
    require_install
    echo -e "${CYAN}Обновляю скрипт...${NC}"
    git -C "$SCRIPT_DIR" reset --hard
    git -C "$SCRIPT_DIR" pull
    echo -e "${CYAN}Обновляю Docker-образ...${NC}"
    cd "$INSTALL_DIR"
    docker compose pull
    docker compose up -d
    docker image prune -f
    echo -e "${GREEN}Всё обновлено. Перезапустите скрипт.${NC}"
    exit 0
}

stop_proxy() {
    require_root
    require_install
    cd "$INSTALL_DIR"
    docker compose down
    echo -e "${GREEN}Прокси остановлен.${NC}"
}

start_proxy() {
    require_root
    require_install
    cd "$INSTALL_DIR"
    docker compose up -d
    echo -e "${GREEN}Прокси запущен.${NC}"
}

restart_proxy() {
    require_root
    require_install
    cd "$INSTALL_DIR"
    docker compose restart
    echo -e "${GREEN}Прокси перезапущен.${NC}"
}

uninstall_proxy() {
    require_root
    require_install
    echo -e "${RED}Это удалит контейнер и все файлы в $INSTALL_DIR.${NC}"
    read -rp "Вы уверены? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cd "$INSTALL_DIR"
        docker compose down
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}Прокси удалён.${NC}"
    else
        echo "Отменено."
    fi
}

show_menu() {
    echo ""
    echo -e "${CYAN}=============================${NC}"
    echo -e "${CYAN}   MTG MTProto Proxy Manager ${NC}"
    echo -e "${CYAN}=============================${NC}"
    echo "  1) Установить прокси"
    echo "  2) Статус и логи"
    echo "  3) Показать ссылку для Telegram"
    echo "  4) Обновить всё"
    echo "  5) Запустить"
    echo "  6) Остановить"
    echo "  7) Перезапустить"
    echo "  8) Удалить прокси"
    echo "  0) Выход"
    echo -e "${CYAN}=============================${NC}"
    echo -n "Выберите пункт: "
}

main() {
    while true; do
        show_menu
        read -r choice
        case $choice in
            1) install_proxy ;;
            2) show_status ;;
            3) show_link ;;
            4) update_proxy ;;
            5) start_proxy ;;
            6) stop_proxy ;;
            7) restart_proxy ;;
            8) uninstall_proxy ;;
            0) echo "Выход."; exit 0 ;;
            *) echo -e "${RED}Неверный пункт.${NC}" ;;
        esac
        echo ""
        read -rp "Нажмите Enter для продолжения..."
    done
}

main
