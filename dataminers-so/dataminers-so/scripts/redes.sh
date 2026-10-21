#!/usr/bin/env bash
# =============================================================================
# redes.sh - Configuración y comprobaciones de red
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Script de redes (Administración de SO)
# Consigna : Automatizar las configuraciones y comprobaciones necesarias para
#            garantizar el correcto funcionamiento de la red.
#
# Qué hace:
#   - Muestra el estado de red (interfaces, IP, gateway, DNS)
#   - Comprueba conectividad: gateway, salida a Internet y resolución DNS
#   - Lista los puertos en escucha y prueba puertos de otros equipos
#   - Configura IP estática con netplan (Ubuntu/Debian), con backup previo y
#     reversión automática si se pierde la conexión
#
# Uso:
#   sudo ./redes.sh <comando> [argumentos]
#   sudo ./redes.sh ayuda
#   DRY_RUN=1 sudo ./redes.sh configurar-ip ...   (muestra sin aplicar)
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/redes.log}"

NETPLAN_DIR="${NETPLAN_DIR:-/etc/netplan}"
NETPLAN_ARCHIVO="${NETPLAN_ARCHIVO:-$NETPLAN_DIR/99-dataminers.yaml}"
NETPLAN_BACKUP_DIR="${NETPLAN_BACKUP_DIR:-/var/backups/netplan}"

IP_PRUEBA="${IP_PRUEBA:-1.1.1.1}"           # para probar salida a Internet
HOST_PRUEBA="${HOST_PRUEBA:-example.com}"   # para probar DNS
DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------- Utilidades --------------------------------
registrar() {
    local nivel="$1"; shift
    local linea
    linea="$(date '+%Y-%m-%d %H:%M:%S') [$nivel] $*"
    echo "$linea"
    if mkdir -p "$LOG_DIR" 2>/dev/null && [ -w "$LOG_DIR" ]; then
        echo "$linea" >> "$LOG_FILE"
    fi
}

info()  { registrar "INFO"  "$@"; }
aviso() { registrar "AVISO" "$@"; }
error() { registrar "ERROR" "$@" >&2; }

verificar_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Este script debe ejecutarse como root (usar sudo)."
        return 1
    fi
}

validar_ip() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -ra octetos <<< "$ip"
    for o in "${octetos[@]}"; do [ "$o" -le 255 ] || return 1; done
}

validar_cidr() {
    # 192.168.1.10/24
    local ip="${1%/*}" mask="${1#*/}"
    [[ "$1" == */* ]] || return 1
    validar_ip "$ip" || return 1
    [[ "$mask" =~ ^[0-9]+$ ]] && [ "$mask" -ge 1 ] && [ "$mask" -le 32 ]
}

interfaz_existe() { [ -d "/sys/class/net/$1" ]; }

requiere_ip() {
    command -v ip >/dev/null 2>&1 || { error "Falta el comando 'ip' (instalar el paquete iproute2)."; return 1; }
}

interfaz_principal() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# ----------------------------------- Estado ------------------------------------
mostrar_estado() {
    requiere_ip || return 1
    echo "=== Interfaces ==="
    ip -brief address 2>/dev/null || ip addr
    echo
    echo "=== Ruta por defecto (gateway) ==="
    ip route show default 2>/dev/null || echo "(sin ruta por defecto)"
    echo
    echo "=== DNS ==="
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns 2>/dev/null | sed 's/^/  /'
    fi
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
    echo
    echo "=== Hostname ==="
    echo "  $(hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
}

# --------------------------------- Comprobaciones -------------------------------
comprobar_red() {
    requiere_ip || return 1
    local fallos=0 iface gw

    iface="$(interfaz_principal)"
    if [ -n "$iface" ]; then
        info "[OK] Interfaz principal: $iface ($(ip -4 -brief address show "$iface" | awk '{print $3}'))"
    else
        error "[FALLO] No hay interfaz con ruta por defecto."
        return 1
    fi

    gw="$(ip route show default | awk '/default/ {print $3; exit}')"
    if ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then
        info "[OK] Gateway $gw responde."
    else
        error "[FALLO] El gateway $gw no responde."
        fallos=$((fallos + 1))
    fi

    if ping -c 2 -W 3 "$IP_PRUEBA" >/dev/null 2>&1; then
        info "[OK] Hay salida a Internet ($IP_PRUEBA)."
    else
        error "[FALLO] Sin salida a Internet ($IP_PRUEBA)."
        fallos=$((fallos + 1))
    fi

    if getent hosts "$HOST_PRUEBA" >/dev/null 2>&1; then
        info "[OK] DNS resuelve $HOST_PRUEBA."
    else
        error "[FALLO] DNS no resuelve $HOST_PRUEBA."
        fallos=$((fallos + 1))
    fi

    if [ "$fallos" -eq 0 ]; then
        info "Comprobación de red: todo correcto."
    else
        error "Comprobación de red: $fallos problema(s)."
        return 1
    fi
}

listar_puertos() {
    info "Puertos TCP/UDP en escucha:"
    if command -v ss >/dev/null 2>&1; then
        ss -tulnH | awk '{printf "  %-5s %-28s\n", $1, $5}' | sort -u
    else
        error "El comando 'ss' no está disponible (paquete iproute2)."
        return 1
    fi
}

probar_puerto() {
    # probar_puerto <host> <puerto>
    local host="${1:-}" puerto="${2:-}"
    [ -z "$host" ] || [ -z "$puerto" ] && { error "Uso: probar_puerto <host> <puerto>"; return 1; }
    [[ "$puerto" =~ ^[0-9]+$ ]] && [ "$puerto" -ge 1 ] && [ "$puerto" -le 65535 ] \
        || { error "Puerto inválido: '$puerto'"; return 1; }

    if timeout 3 bash -c "exec 3<>/dev/tcp/$host/$puerto" 2>/dev/null; then
        info "[OK] $host:$puerto está abierto."
    else
        error "[FALLO] $host:$puerto no responde (cerrado o filtrado)."
        return 1
    fi
}

# ---------------------------------- IP estática ---------------------------------
configurar_ip() {
    # configurar_ip <interfaz> <ip/cidr> <gateway> [dns1,dns2]
    local iface="${1:-}" cidr="${2:-}" gw="${3:-}" dns="${4:-1.1.1.1,8.8.8.8}"
    if [ -z "$iface" ] || [ -z "$cidr" ] || [ -z "$gw" ]; then
        error "Uso: configurar_ip <interfaz> <ip/cidr> <gateway> [dns1,dns2]"
        return 1
    fi

    requiere_ip || return 1
    interfaz_existe "$iface" || { error "La interfaz '$iface' no existe. Ver: ip -br a"; return 1; }
    validar_cidr "$cidr"     || { error "IP/máscara inválida: '$cidr' (ej: 192.168.1.10/24)"; return 1; }
    validar_ip "$gw"         || { error "Gateway inválido: '$gw'"; return 1; }

    local d
    IFS=',' read -ra lista_dns <<< "$dns"
    for d in "${lista_dns[@]}"; do
        validar_ip "$d" || { error "DNS inválido: '$d'"; return 1; }
    done

    local yaml
    yaml="network:
  version: 2
  renderer: networkd
  ethernets:
    $iface:
      dhcp4: false
      addresses:
        - $cidr
      routes:
        - to: default
          via: $gw
      nameservers:
        addresses: [${dns}]"

    if [ "$DRY_RUN" = "1" ]; then
        info "[SIMULACRO] Se escribiría $NETPLAN_ARCHIVO con:"
        echo "$yaml"
        return 0
    fi

    command -v netplan >/dev/null 2>&1 || { error "netplan no está instalado (¿no es Ubuntu?)."; return 1; }

    # Backup de la configuración actual
    mkdir -p "$NETPLAN_BACKUP_DIR"
    local backup="$NETPLAN_BACKUP_DIR/netplan_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup"
    cp -a "$NETPLAN_DIR"/. "$backup"/ 2>/dev/null
    info "Backup de la configuración actual en $backup"

    # Para que no se pisen: se desactivan (renombran) otros yaml que definan la misma interfaz
    local f
    for f in "$NETPLAN_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        [ "$f" = "$NETPLAN_ARCHIVO" ] && continue
        if grep -q "$iface" "$f"; then
            mv "$f" "$f.desactivado"
            aviso "Se desactivó $f (definía '$iface')."
        fi
    done

    echo "$yaml" > "$NETPLAN_ARCHIVO"
    chmod 600 "$NETPLAN_ARCHIVO"

    if ! netplan generate 2>/dev/null; then
        error "La configuración generada no es válida. Restaurando backup..."
        restaurar_backup_netplan "$backup"
        return 1
    fi

    info "Aplicando con 'netplan try' (si no confirmás en 120 s, vuelve a la config anterior)..."
    if netplan try --timeout 120; then
        info "IP estática $cidr aplicada en $iface (gateway $gw)."
    else
        error "No se confirmó el cambio. Se restauró la configuración anterior."
        restaurar_backup_netplan "$backup"
        return 1
    fi
}

restaurar_backup_netplan() {
    local backup="$1"
    rm -f "$NETPLAN_DIR"/*.yaml
    cp -a "$backup"/. "$NETPLAN_DIR"/ 2>/dev/null
    netplan apply 2>/dev/null
    aviso "Configuración netplan restaurada desde $backup"
}

# ------------------------------------- Ayuda ------------------------------------
mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [argumentos]

Consultas:
  estado                                   Interfaces, IP, gateway y DNS
  comprobar                                Prueba gateway, Internet y DNS
  puertos                                  Lista los puertos en escucha
  probar-puerto <host> <puerto>            Prueba si un puerto remoto está abierto

Configuración:
  configurar-ip <iface> <ip/cidr> <gateway> [dns1,dns2]
                                           IP estática con netplan (backup + reversión)

  ayuda                                    Muestra esta ayuda

Ejemplos:
  sudo $0 comprobar
  sudo $0 probar-puerto 192.168.1.50 22
  sudo DRY_RUN=1 $0 configurar-ip enp0s3 192.168.1.10/24 192.168.1.1
EOF
}

# -------------------------------------- Main ------------------------------------
main() {
    local comando="${1:-ayuda}"
    [ $# -gt 0 ] && shift

    case "$comando" in
        ayuda|-h|--help) mostrar_ayuda; return 0 ;;
    esac

    verificar_root || return 1

    case "$comando" in
        estado)          mostrar_estado ;;
        comprobar)       comprobar_red ;;
        puertos)         listar_puertos ;;
        probar-puerto)   probar_puerto "$@" ;;
        configurar-ip)   configurar_ip "$@" ;;
        *)               error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
