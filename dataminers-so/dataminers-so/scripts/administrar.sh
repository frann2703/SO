#!/usr/bin/env bash
# =============================================================================
# administrar.sh - Administración centralizada del servidor
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Integrar scripts de forma modular (Administración de SO)
# Consigna : Organizar los diferentes scripts en módulos independientes y crear
#            una estructura que permita ejecutarlos y administrarlos de forma
#            centralizada.
#
# Cada módulo es un script independiente que también funciona solo. Este script
# los organiza y los ejecuta desde un único punto:
#
#   usuarios · grupos · backups · restauracion · respaldo
#   redes · basedatos · firewall · logs
#
# Uso:
#   sudo ./administrar.sh <modulo> <comando> [argumentos]   Ejecuta un módulo
#   sudo ./administrar.sh menu                              Menú interactivo
#   sudo ./administrar.sh estado                            Estado general del servidor
#   sudo ./administrar.sh inicializar                       Configuración inicial guiada
#   sudo ./administrar.sh modulos                           Lista los módulos
#   sudo ./administrar.sh ayuda
#
# Ejemplos:
#   sudo ./administrar.sh usuarios crear mperez "Maria Perez" dm_dev
#   sudo ./administrar.sh backups completo
#   sudo ./administrar.sh firewall estado
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
DIR_SCRIPTS="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/administrar.log}"

# Módulo -> archivo | descripción
declare -A MODULO_ARCHIVO=(
    [usuarios]="usuarios.sh"
    [grupos]="grupos.sh"
    [backups]="backups.sh"
    [restauracion]="probar_restauracion.sh"
    [respaldo]="servidor_respaldo.sh"
    [redes]="redes.sh"
    [basedatos]="basedatos.sh"
    [firewall]="firewall.sh"
    [logs]="logs.sh"
)
declare -A MODULO_DESC=(
    [usuarios]="Altas, bajas y modificaciones de usuarios"
    [grupos]="Grupos, membresías y permisos de directorios"
    [backups]="Copias de seguridad de archivos y base de datos"
    [restauracion]="Pruebas de restauración de backups"
    [respaldo]="Configuración del servidor de respaldo"
    [redes]="Configuración y comprobación de red"
    [basedatos]="Preparación de la base de datos MySQL"
    [firewall]="Reglas de firewall (UFW)"
    [logs]="Rotación y monitoreo de logs"
)
ORDEN_MODULOS=(usuarios grupos backups restauracion respaldo redes basedatos firewall logs)

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

confirmar() {
    # confirmar "pregunta"  -> 0 si responde s/S
    local r
    read -r -p "$1 [s/N]: " r
    [[ "$r" =~ ^[sSyY]$ ]]
}

# ---------------------------------- Módulos -------------------------------------
ruta_modulo() {
    local modulo="$1" archivo
    archivo="${MODULO_ARCHIVO[$modulo]:-}"
    [ -z "$archivo" ] && return 1
    echo "$DIR_SCRIPTS/$archivo"
}

ejecutar_modulo() {
    # ejecutar_modulo <modulo> [comando y argumentos...]
    local modulo="${1:-}"
    [ $# -gt 0 ] && shift
    local ruta
    ruta="$(ruta_modulo "$modulo")" || { error "Módulo desconocido: '$modulo' (ver: $0 modulos)"; return 1; }
    [ -f "$ruta" ] || { error "No se encuentra el archivo del módulo: $ruta"; return 1; }

    bash "$ruta" "$@"
}

listar_modulos() {
    echo "Módulos disponibles:"
    local m estado
    for m in "${ORDEN_MODULOS[@]}"; do
        if [ -f "$DIR_SCRIPTS/${MODULO_ARCHIVO[$m]}" ]; then estado="ok"; else estado="FALTA ARCHIVO"; fi
        printf "  %-13s %-45s [%s]\n" "$m" "${MODULO_DESC[$m]}" "$estado"
    done
    echo
    echo "Ayuda de un módulo:  $0 <modulo> ayuda"
}

# ------------------------------------ Estado ------------------------------------
estado_general() {
    echo "=== Estado del servidor: $(hostname) - $(date '+%d/%m/%Y %H:%M') ==="
    echo "Sistema      : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
    echo "Uptime       : $(uptime -p 2>/dev/null)"
    echo "IP           : $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "Disco /      : $(df -h / | awk 'NR==2 {print $3 " usados de " $2 " (" $5 ")"}')"
    echo "Memoria      : $(free -h | awk '/^Mem:/ {print $3 " usados de " $2}')"
    echo

    echo "--- Servicios ---"
    local srv
    for srv in ssh sshd docker cron; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$srv.service"; then
            printf "  %-8s %s\n" "$srv" "$(systemctl is-active "$srv" 2>/dev/null)"
        fi
    done

    echo "--- Firewall ---"
    if command -v ufw >/dev/null 2>&1; then
        echo "  ufw: $(ufw status 2>/dev/null | head -1 | sed 's/Status: //')"
    else
        echo "  ufw no instalado"
    fi

    echo "--- Contenedores ---"
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '  {{.Names}}  {{.Status}}' 2>/dev/null || echo "  (sin acceso a Docker)"
    else
        echo "  Docker no instalado"
    fi

    echo "--- Último backup ---"
    local dir="${BACKUP_DIR:-/var/backups/dataminers}" ultimo
    ultimo="$(ls -1t "$dir"/*.tar.gz "$dir"/*.sql.gz 2>/dev/null | head -1)"
    if [ -n "$ultimo" ]; then
        echo "  $(basename "$ultimo") ($(date -r "$ultimo" '+%d/%m/%Y %H:%M'))"
    else
        echo "  Todavía no hay backups en $dir"
    fi

    echo "--- Cron de backup ---"
    [ -f /etc/cron.d/dataminers-backup ] && echo "  programado" || echo "  no programado"
}

# ---------------------------------- Inicialización ------------------------------
inicializar() {
    verificar_root || return 1
    echo "Configuración inicial del servidor (se pide confirmación en cada paso)."
    echo

    local pasos=(
        "grupos|base|Crear los grupos base del proyecto"
        "logs|configurar|Configurar rotación de logs"
        "firewall|aplicar|Aplicar reglas de firewall (revisar SSH_PUERTO / SSH_DESDE antes)"
        "backups|cron-instalar|Programar el backup diario"
    )

    local paso modulo comando desc
    for paso in "${pasos[@]}"; do
        IFS='|' read -r modulo comando desc <<< "$paso"
        echo "-> $desc"
        if confirmar "   ¿Ejecutar '$modulo $comando'?"; then
            ejecutar_modulo "$modulo" "$comando" || aviso "El paso '$modulo $comando' terminó con errores."
        else
            echo "   Omitido."
        fi
        echo
    done

    info "Inicialización finalizada. Pasos manuales pendientes: usuarios, base de datos y servidor de respaldo."
}

# -------------------------------------- Menú -----------------------------------
menu() {
    verificar_root || return 1
    local opcion modulo comando

    while true; do
        echo
        echo "===== Administración DataMiners ====="
        local i=1
        for modulo in "${ORDEN_MODULOS[@]}"; do
            printf "  %d) %-13s %s\n" "$i" "$modulo" "${MODULO_DESC[$modulo]}"
            i=$((i + 1))
        done
        echo "  e) Estado general"
        echo "  i) Inicialización guiada"
        echo "  q) Salir"
        read -r -p "Opción: " opcion

        case "$opcion" in
            q|Q) return 0 ;;
            e|E) estado_general ;;
            i|I) inicializar ;;
            [1-9])
                modulo="${ORDEN_MODULOS[$((opcion - 1))]:-}"
                [ -z "$modulo" ] && { aviso "Opción inválida."; continue; }
                ejecutar_modulo "$modulo" ayuda
                echo
                read -r -p "Comando y argumentos (vacío = volver): " comando
                # shellcheck disable=SC2086
                [ -n "$comando" ] && ejecutar_modulo "$modulo" $comando
                ;;
            *) aviso "Opción inválida." ;;
        esac
    done
}

# ------------------------------------- Ayuda ------------------------------------
mostrar_ayuda() {
    sed -n '/^# Uso:/,/^# =====/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    echo
    listar_modulos
}

# -------------------------------------- Main ------------------------------------
main() {
    local comando="${1:-ayuda}"
    [ $# -gt 0 ] && shift

    case "$comando" in
        ayuda|-h|--help) mostrar_ayuda; return 0 ;;
        modulos)         listar_modulos; return 0 ;;
    esac

    verificar_root || return 1

    case "$comando" in
        menu)        menu ;;
        estado)      estado_general ;;
        inicializar) inicializar ;;
        *)
            # Cualquier otra cosa se interpreta como <modulo> <comando> ...
            if ruta_modulo "$comando" >/dev/null; then
                ejecutar_modulo "$comando" "$@"
            else
                error "Comando o módulo desconocido: '$comando'"
                mostrar_ayuda
                return 1
            fi
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
