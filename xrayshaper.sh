#!/bin/bash
# Xrayshaper 1.0.0 — двусторонний fair-use лимитер для Xray/V2Ray с контролем 95ого перцентиля
# ============================================================================================
# Тип очереди: HTB (Egress/Ingress) + fq_codel (Egress/Ingress) + ifb (Ingress)
# Автор: @hydraponique
# Совместимость: Ubuntu 18.04+/Debian 10+ (Linux >= 5.15, iproute2 >= 6.0)

VERSION=100

CONFIG="/etc/xrayshaper.conf"
SERVICE="/etc/systemd/system/xrayshaper.service"
SCRIPT_PATH="/usr/local/bin/xrayshaper"
LOG_FILE="/var/log/xrayshaper.log"

# --- Логирование для отладки ---
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- Проверка на ОС ---
check_ubuntu_debian() {
    if ! [[ -f /etc/debian_version ]] && ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
        echo "Ошибка: Этот скрипт поддерживает только Ubuntu 18.04+/Debian 10+ (ядро Linux >= 5.15)"
        exit 1
    fi
}

# --- Загрузка модуля ifb ---
load_ifb_module() {
    # Пробуем загрузить модуль
    if modprobe ifb numifbs=1 2>/dev/null; then
        echo "Модуль ifb успешно загружен"
        return 0
    fi
	
    echo "Ошибка: не удалось загрузить модуль ifb: ядро Linux в вашей системе собрано без сетевых модулей - дальнейшая установка невозможна"
    return 1
}

# --- Проверка зависимостей ---
check_dependencies() {
    local deps=("tc" "ip" "iptables" "systemctl")
    local missing=()
    local packages=()
    
    # Проверяем какие утилиты отсутствуют
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    # Определяем какие пакеты нужно установить
    if [[ ${#missing[@]} -gt 0 ]]; then
        # Сопоставляем утилиты с пакетами
        for dep in "${missing[@]}"; do
            case "$dep" in
                tc|ip)
                    packages+=("iproute2")
                    ;;
                iptables)
                    packages+=("iptables")
                    ;;
                systemctl)
                    packages+=("systemd")
                    ;;
            esac
        done
        
        # Убираем дубликаты
        packages=($(echo "${packages[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
		
        echo "Обнаружены отсутствующие зависимости: ${missing[*]} - дальнейшая установка невозможна"
		
        echo "Установите вручную отсутствующие пакеты (apt install ${packages[*]}) и повторите установку"
		
		exit 1
    fi
    
    # Загружаем модуль ifb
    if ! load_ifb_module; then
        exit 1
    fi
    
    echo "Все зависимости на месте!"
}

# --- Валидация формата скорости ---
validate_rate() {
    local rate="$1"
    local param_name="$2"
    
    if ! [[ "$rate" =~ ^[0-9]+[kmg]bit$ ]]; then
        echo "Ошибка: $param_name '$rate' имеет неверный формат"
        echo "Используйте формат: число + kbit/mbit/gbit (например: 10mbit, 512kbit)"
        return 1
    fi
    
    # Проверяем, что число не нулевое
    local num_value=$(echo "$rate" | sed 's/[kmg]bit//')
    if [[ "$num_value" -eq 0 ]]; then
        echo "Ошибка: $param_name не может быть нулевым"
        return 1
    fi
    
    return 0
}

# --- Валидация формата burst ---
validate_burst() {
    local burst="$1"
    local param_name="$2"
    
    if ! [[ "$burst" =~ ^[0-9]+[km]?$ ]]; then
        echo "Ошибка: $param_name '$burst' имеет неверный формат"
        echo "Используйте формат: число + k/m (например: 1m, 512k)"
        return 1
    fi
    
    return 0
}

# --- Валидация интерфейса ---
validate_interface() {
    local iface="$1"
    
    if ! ip link show "$iface" &>/dev/null; then
        echo "Ошибка: интерфейс '$iface' не существует"
        echo "Доступные интерфейсы:"
        ip -o link show | awk -F': ' '{print "  - " $2}'
        return 1
    fi
    
    # Проверяем, что это не loopback
    if [[ "$iface" == "lo" ]]; then
        echo "Ошибка: нельзя использовать loopback интерфейс"
        return 1
    fi
    
    return 0
}

# --- Улучшенное автоопределение активного интерфейса ---
detect_iface() {
    local iface candidates=()
    
    # 1. Пробуем получить интерфейс из default route
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -n "$iface" && -d "/sys/class/net/$iface" ]]; then
        # Проверяем, что интерфейс действительно активен
        local operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)
        if [[ "$operstate" == "up" || "$operstate" == "unknown" ]]; then
            echo "$iface"
            return 0
        fi
    fi
    
    # 2. Собираем список всех физических интерфейсов (исключаем виртуальные)
    while IFS= read -r netdev; do
        [[ -z "$netdev" ]] && continue
        
        # Пропускаем loopback, виртуальные и docker интерфейсы
        [[ "$netdev" == lo* ]] && continue
        [[ "$netdev" == docker* ]] && continue
        [[ "$netdev" == br-* ]] && continue
        [[ "$netdev" == veth* ]] && continue
        [[ "$netdev" == ifb* ]] && continue
        
        # Проверяем, что интерфейс существует и доступен
        if [[ -d "/sys/class/net/$netdev" ]]; then
            local operstate=$(cat "/sys/class/net/$netdev/operstate" 2>/dev/null)
            local iftype=$(cat "/sys/class/net/$netdev/type" 2>/dev/null)
            
            # Проверяем тип интерфейса (1 = ethernet, 772 = loopback)
            if [[ "$iftype" == "1" ]]; then
                # Предпочитаем интерфейсы в состоянии "up"
                if [[ "$operstate" == "up" ]]; then
                    candidates=("$netdev" "${candidates[@]}")  # Добавляем в начало
                elif [[ "$operstate" == "unknown" || "$operstate" == "down" ]]; then
                    candidates+=("$netdev")  # Добавляем в конец
                fi
            fi
        fi
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}')
    
    # 3. Выбираем лучший кандидат
    if [[ ${#candidates[@]} -gt 0 ]]; then
        echo "${candidates[0]}"
        return 0
    fi
    
    # 4. Fallback: пробуем стандартные имена
    for fallback in eth0 ens3 enp0s3 eno1; do
        if [[ -d "/sys/class/net/$fallback" ]]; then
            echo "$fallback"
            return 0
        fi
    done
    
    # 5. Последняя попытка: любой не-loopback интерфейс
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '!/lo:/ {print $2; exit}')
    if [[ -n "$iface" ]]; then
        echo "$iface"
        return 0
    fi
    
    # 6. Если ничего не найдено
    echo "eth0"
    return 1
}

# --- Валидация конфигурации ---
validate_config() {
    source "$CONFIG" 2>/dev/null || { echo "Конфигурация не найдена."; return 1; }
    
    local errors=0
    
    # Проверка интерфейса
    if ! validate_interface "$IFACE"; then
        ((errors++))
    fi
    
    # Проверка скорости
    if ! validate_rate "$RATE" "RATE"; then
        ((errors++))
    fi
    
    if ! validate_rate "$CEIL" "CEIL"; then
        ((errors++))
    fi
    
    # Проверка burst параметров
    if ! validate_burst "$BURST" "BURST"; then
        ((errors++))
    fi
    
    if ! validate_burst "$CBURST" "CBURST"; then
        ((errors++))
    fi
    
    # Проверка, что CEIL >= RATE
    local rate_num=$(echo "$RATE" | sed 's/[kmg]bit//')
    local ceil_num=$(echo "$CEIL" | sed 's/[kmg]bit//')
    local rate_unit=$(echo "$RATE" | sed 's/[0-9]*//')
    local ceil_unit=$(echo "$CEIL" | sed 's/[0-9]*//')
    
    # Конвертируем в килобиты для сравнения
    local rate_kbits=$rate_num
    local ceil_kbits=$ceil_num
    
    case "$rate_unit" in
        mbit) rate_kbits=$((rate_num * 1000)) ;;
        gbit) rate_kbits=$((rate_num * 1000000)) ;;
    esac
    
    case "$ceil_unit" in
        mbit) ceil_kbits=$((ceil_num * 1000)) ;;
        gbit) ceil_kbits=$((ceil_num * 1000000)) ;;
    esac
    
    if [[ "$ceil_kbits" -lt "$rate_kbits" ]]; then
        echo "Ошибка: CEIL ($CEIL) не может быть меньше RATE ($RATE)"
        ((errors++))
    fi
    
    return $errors
}

# --- Интерактивный ввод с валидацией ---
read_validated() {
    local prompt="$1"
    local default="$2"
    local validator="$3"
    local value
    
    while true; do
        read -p "$prompt" value
        value=${value:-$default}
        
        if $validator "$value"; then
            echo "$value"
            return 0
        fi
        echo "Пожалуйста, введите корректное значение"
    done
}

# --- Скачивание скрипта с GitHub ---
download_script() {
    local url="https://raw.githubusercontent.com/hydraponique/Xrayshaper/main/xrayshaper.sh"
    log_message "Скачивание скрипта с GitHub..."
    
    if ! curl -sL "$url" -o "$SCRIPT_PATH" 2>/dev/null; then
        echo "Ошибка: не удалось скачать скрипт"
        return 1
    fi
    
    if ! chmod +x "$SCRIPT_PATH" 2>/dev/null; then
        echo "Ошибка: не удалось установить права на скрипт"
        return 1
    fi
    
    log_message "Скрипт успешно скачан и установлен в $SCRIPT_PATH"
    return 0
}

# --- Установка параметров ---
install_shaper() {
    clear
    echo "=== Установка Xrayshaper ==="
    
    # Проверяем что это Ubuntu/Debian
    check_ubuntu_debian
    
    # Проверяем и устанавливаем зависимости
    check_dependencies
    
    echo "Введите параметры (нажмите Enter, чтобы оставить значение по умолчанию)"
    echo

    DEFAULT_IFACE=$(detect_iface)
    if [[ $? -ne 0 ]]; then
        echo "Предупреждение: не удалось автоматически определить интерфейс"
    fi
    
    echo "Автоопределённый интерфейс: $DEFAULT_IFACE"
    IFACE=$(read_validated "Интерфейс внешней сети [${DEFAULT_IFACE}]: " "$DEFAULT_IFACE" "validate_interface")

    IFB="ifb0"

    RATE=$(read_validated "Средняя скорость ограничения (95-й перцентиль) [5mbit]: " "5mbit" "validate_rate")

    CEIL=$(read_validated "Максимальный потолок скорости [1gbit]: " "1gbit" "validate_rate")

    BURST=$(read_validated "Burst (кратковременный всплеск, буфер пакетов) [1m]: " "1m" "validate_burst")

    CBURST=$(read_validated "CBurst (burst для контрольных пакетов) [1m]: " "1m" "validate_burst")

    # Сохраняем конфигурацию
    cat > "$CONFIG" <<EOF
IFACE="$IFACE"
IFB="$IFB"
RATE="$RATE"
CEIL="$CEIL"
BURST="$BURST"
CBURST="$CBURST"
EOF

    # ИСПРАВЛЕНИЕ: Скачиваем скрипт с GitHub вместо cp $0
    echo "Установка скрипта..."
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    
    if ! download_script; then
        # Fallback: если скачивание не сработало, копируем текущий скрипт
        if [[ -s "$0" && "$0" != "/dev/stdin" && "$0" != "/proc/self/fd"* ]]; then
            log_message "Fallback: копирование текущего скрипта"
            cp "$0" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
        else
            echo "Ошибка: не удалось установить скрипт"
            exit 1
        fi
    fi

    # Создаём systemd-сервис
    echo "Создаётся systemd-сервис..."
    cat > "$SERVICE" <<'SEOF'
[Unit]
Description=Xrayshaper — fair bandwidth limiter for Xray/V2Ray with 95th percentile control
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xrayshaper enable
ExecStop=/usr/local/bin/xrayshaper disable
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SEOF

    # Перезагружаем systemd
    systemctl daemon-reload
    systemctl enable xrayshaper
    systemctl start xrayshaper
    
    echo
    echo "Xrayshaper установлен, включен автоматически и добавлен в автозагрузку."
    read -n1 -r -p "Нажмите любую клавишу для продолжения..." key
	sleep 1
	show_status
}

# --- Переустановка параметров ---
reinstall_shaper() {
	# Отключаем systemd-сервис
    systemctl disable --now xrayshaper 2>/dev/null
	sleep 1
	install_shaper
}

# --- Команда help ---
help_screen() {
	echo "Команды для ручного администрирования:"
	echo "==============================================================="
	echo "sudo xrayshaper on - включить шейпинг"
	echo "sudo xrayshaper off - отключить шейпинг"
	echo "sudo xrayshaper status - посмотреть состояние"
	echo "sudo xrayshaper reinstall - переустановить с новыми значениями"
	exit 1
}

# --- Включение шейпинга ---
apply_shaping() {
    echo "Проверка конфигурации..."
    if ! validate_config; then
        echo "Ошибка: некорректная конфигурация"
        exit 1
    fi
    
    source "$CONFIG"
    
    echo "Применение шейпинга на интерфейсе $IFACE..."
    
    # Очистка предыдущих правил
    tc qdisc del dev $IFACE root 2>/dev/null
    tc qdisc del dev $IFACE ingress 2>/dev/null
    tc qdisc del dev $IFB root 2>/dev/null
    ip link set $IFB down 2>/dev/null
    ip link del $IFB 2>/dev/null
    iptables -t mangle -F OUTPUT 2>/dev/null
    iptables -t mangle -F INPUT 2>/dev/null

    # Создание и настройка IFB для входящего трафика
    modprobe ifb numifbs=1 2>/dev/null
    ip link add name $IFB type ifb 2>/dev/null
    ip link set $IFB up 2>/dev/null

    # Маркировка системного (неограниченного) трафика - ИСХОДЯЩИЙ
    iptables -t mangle -A OUTPUT -p tcp -m multiport --sports 22,53,853 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -p tcp -m multiport --dports 22,53,853 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -p udp -m multiport --sports 53,853,123 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -p udp -m multiport --dports 53,853,123 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -p icmp -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -d 127.0.0.0/8 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -d 10.0.0.0/8 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -d 172.16.0.0/12 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -d 192.168.0.0/16 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A OUTPUT -p tcp -m length --length 0:128 -m tcp --tcp-flags SYN,ACK,FIN,RST ACK -j MARK --set-mark 100 2>/dev/null

    # Маркировка системного (неограниченного) трафика - ВХОДЯЩИЙ
    iptables -t mangle -A INPUT -p tcp -m multiport --sports 22,53,853 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -p tcp -m multiport --dports 22,53,853 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -p udp -m multiport --sports 53,853,123 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -p udp -m multiport --dports 53,853,123 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -p icmp -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -s 127.0.0.0/8 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -s 10.0.0.0/8 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -s 172.16.0.0/12 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -s 192.168.0.0/16 -j MARK --set-mark 100 2>/dev/null
    iptables -t mangle -A INPUT -p tcp -m length --length 0:128 -m tcp --tcp-flags SYN,ACK,FIN,RST ACK -j MARK --set-mark 100 2>/dev/null

    # Всё остальное маркируем ограниченным
    iptables -t mangle -A OUTPUT -j MARK --set-mark 10 2>/dev/null
    iptables -t mangle -A INPUT -j MARK --set-mark 10 2>/dev/null

    # Исходящий трафик (upload)
    tc qdisc add dev $IFACE root handle 1: htb default 10 r2q 25 2>/dev/null
    tc class add dev $IFACE parent 1: classid 1:10 htb rate $RATE ceil $CEIL burst $BURST cburst $CBURST 2>/dev/null
    tc class add dev $IFACE parent 1: classid 1:20 htb rate $CEIL ceil $CEIL 2>/dev/null
    tc qdisc add dev $IFACE parent 1:10 handle 10: fq_codel limit 800 target 4ms interval 60ms noecn quantum 600 2>/dev/null
    tc filter add dev $IFACE parent 1: protocol ip handle 10 fw flowid 1:10 2>/dev/null
    tc filter add dev $IFACE parent 1: protocol ip handle 100 fw flowid 1:20 2>/dev/null

    # Входящий трафик (download)
    tc qdisc add dev $IFACE handle ffff: ingress 2>/dev/null
    tc filter add dev $IFACE parent ffff: protocol all matchall action mirred egress redirect dev $IFB 2>/dev/null
    tc qdisc add dev $IFB root handle 2: htb default 10 r2q 25 2>/dev/null
    tc class add dev $IFB parent 2: classid 2:10 htb rate $RATE ceil $CEIL burst $BURST cburst $CBURST 2>/dev/null
    tc class add dev $IFB parent 2: classid 2:20 htb rate $CEIL ceil $CEIL 2>/dev/null
    tc qdisc add dev $IFB parent 2:10 handle 20: fq_codel limit 800 target 4ms interval 60ms noecn quantum 600 2>/dev/null
    tc filter add dev $IFB parent 2: protocol ip handle 10 fw flowid 2:10 2>/dev/null
    tc filter add dev $IFB parent 2: protocol ip handle 100 fw flowid 2:20 2>/dev/null

    ip link set dev $IFACE txqueuelen 1000 2>/dev/null
    log_message "Двусторонний шейпинг активирован."
    echo "Двусторонний шейпинг активирован."
}

# --- Отключение ---
disable_shaping() {
    if ! validate_config 2>/dev/null; then
        log_message "Конфигурация не найдена или некорректна"
        echo "Конфигурация не найдена или некорректна"
        return
    fi
    
    source "$CONFIG"
    
    log_message "Отключение шейпинга на интерфейсе $IFACE..."
    echo "Отключение шейпинга на интерфейсе $IFACE..."
    
    tc qdisc del dev $IFACE root 2>/dev/null
    tc qdisc del dev $IFACE ingress 2>/dev/null
    tc qdisc del dev $IFB root 2>/dev/null
    ip link set $IFB down 2>/dev/null
    ip link del $IFB 2>/dev/null
    iptables -t mangle -F OUTPUT 2>/dev/null
    iptables -t mangle -F INPUT 2>/dev/null
    
    log_message "Шейпинг отключен."
    echo "Шейпинг отключен."
}

# --- Меню состояния ---
show_status() {
    clear
    echo "------------Xrayshaper 1.0.0------------"
    systemctl is-active --quiet xrayshaper && STATUS="✓ активен" || STATUS="✗ не активен"
    systemctl is-enabled --quiet xrayshaper && ENABLED="✓ в автозагрузке" || ENABLED="✗ не в автозагрузке"
	systemctl is-failed --quiet xrayshaper && STATUS="✗ ошибка"
	
    echo "Сервис:      $STATUS ($ENABLED)"
    
    if [ -f "$CONFIG" ]; then
        if validate_config; then
            source "$CONFIG"
            echo "Конфиг:      ✓ валидный"
        else
            echo "Конфиг:      ✗ ошибка"
        fi
    else
        echo "Конфиг не найден"
    fi
	
    echo "-----------------Конфиг-----------------"
    [ -f "$CONFIG" ] && source "$CONFIG" 2>/dev/null
    echo "Интерфейс:   ${IFACE:-eth0}"
    echo "Вирт. ifb:   ${IFB:-ifb0}"
    echo "Тип очереди: HTB + FQ-CoDel"
    echo "Ограничение: ${RATE:-5mbit} (ceil ${CEIL:-1gbit})"
    echo "Burst:       ${BURST:-1m}"
    echo "CBurst:      ${CBURST:-1m}"
	if [ "$STATUS" = "✓ активен" ]; then
		echo "-----------------Статус-----------------"
		echo "Egress (исходящий ${IFACE:-eth0}):"
		tc -s class show dev ${IFACE:-eth0} 2>/dev/null | grep -E "class htb 1:" | sed 's/^/  /'
		echo "Ingress (входящий ${IFB:-ifb0}):"
		tc -s class show dev ${IFB:-ifb0} 2>/dev/null | grep -E "class htb 2:" | sed 's/^/  /'
		echo "----------------------------------------"
		echo "  ${IFACE:-eth0} → 1:10 (upload)"
		echo "  ${IFB:-ifb0} → 2:10 (download)"
	fi
	echo "----------------------------------------"
	echo
    echo "1) Включить шейпинг"
    echo "2) Выключить шейпинг"
    echo "3) Переустановить"
    echo "4) Выход"
    echo -n "Выберите действие [1-4]: "
    read choice
    case $choice in
        1)
		systemctl start xrayshaper
		sleep 3
		show_status
		;;
        2)
		systemctl stop xrayshaper
		sleep 3
		show_status
		;;
        3) reinstall_shaper ;;
        4) exit 0 ;;
    esac
}

# --- Аргументы запуска ---
case "$1" in
    on)
	systemctl start xrayshaper
	echo "Xrayshaper включен."
	;;
    off)
	systemctl stop xrayshaper
	echo "Xrayshaper отключен."
	;;
    enable) apply_shaping ;;
    disable) disable_shaping ;;
	status) show_status ;;
	reinstall) reinstall_shaper ;;
	help) help_screen ;;
    *)
        if [ ! -f "$CONFIG" ]; then
            install_shaper
        else
            show_status
        fi
        ;;
esac
