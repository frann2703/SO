#!/usr/bin/env bash
# =============================================================================
# logs.sh - Configuración y gestión de registros del sistema
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Script de logs (Administración de SO)
#
# Qué hace:
#   - Configura la rotación de los logs de los scripts (logrotate)
#   - Limita el tamaño del journal del sistema (journald)
#   - Facilita el monitoreo: errores recientes, accesos SSH fallidos, uso de
#     sudo, logs de los contenedores y resumen general
#
# Uso:
#   sudo ./logs.sh <comando> [argumentos]
#   sudo ./logs.sh ayuda
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/logs.log}"

LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/dataminers}"
JOURNALD_DIR="${JOURNALD_DIR:-/etc/systemd/journald.conf.d}"
JOURNALD_FILE="${JOURNALD_FILE:-$JOURNALD_DIR/dataminers.conf}"

ROTAR_CADA="${ROTAR_CADA:-weekly}"          # daily | weekly | monthly
ROTAR_CANTIDAD="${ROTAR_CANTIDAD:-8}"       # cuántos archivos rotados se conservan
JOURNAL_MAX="${JOURNAL_MAX:-500M}"          # espacio máximo del journal
JOURNAL_RETENCION="${JOURNAL_RETENCION:-1month}"

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

es_numero() { [[ "$1" =~ ^[0-9]+$ ]]; }

# --------------------------------- Configuración --------------------------------
configurar_logrotate() {
    [[ "$ROTAR_CADA" =~ ^(daily|weekly|monthly)$ ]] || { error "ROTAR_CADA inválido: '$ROTAR_CADA'"; return 1; }
    es_numero "$ROTAR_CANTIDAD" || { error "ROTAR_CANTIDAD inválido: '$ROTAR_CANTIDAD'"; return 1; }

    mkdir -p "$LOG_DIR"
    chmod 750 "$LOG_DIR"

    cat > "$LOGROTATE_FILE" <<EOF
# Rotación de logs DataMiners (generado por logs.sh)
$LOG_DIR/*.log {
    $ROTAR_CADA
    rotate $ROTAR_CANTIDAD
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF
    chmod 644 "$LOGROTATE_FILE"

    if command -v logrotate >/dev/null 2>&1; then
        if logrotate -d "$LOGROTATE_FILE" >/dev/null 2>&1; then
            info "Rotación configurada y validada: $ROTAR_CADA, se conservan $ROTAR_CANTIDAD ($LOGROTATE_FILE)."
        else
            error "La configuración de logrotate tiene errores: $LOGROTATE_FILE"
            return 1
        fi
    else
        aviso "logrotate no está instalado (apt install logrotate). Configuración escrita en $LOGROTATE_FILE."
    fi
}

configurar_journald() {
    mkdir -p "$JOURNALD_DIR"
    cat > "$JOURNALD_FILE" <<EOF
# Límite del journal DataMiners (generado por logs.sh)
[Journal]
Storage=persistent
SystemMaxUse=$JOURNAL_MAX
MaxRetentionSec=$JOURNAL_RETENCION
Compress=yes
EOF
    chmod 644 "$JOURNALD_FILE"

    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        systemctl restart systemd-journald && info "journald reiniciado: máximo $JOURNAL_MAX, retención $JOURNAL_RETENCION."
    else
        info "journald configurado ($JOURNALD_FILE); se aplicará al reiniciar el servicio."
    fi
}

configurar_todo() {
    local fallos=0
    configurar_logrotate || fallos=$((fallos + 1))
    configurar_journald  || fallos=$((fallos + 1))
    [ "$fallos" -eq 0 ] && info "Gestión de logs configurada."
    [ "$fallos" -eq 0 ]
}

rotar_ahora() {
    command -v logrotate >/dev/null 2>&1 || { error "logrotate no está instalado."; return 1; }
    logrotate -f "$LOGROTATE_FILE" && info "Rotación forzada ejecutada."
}

# ------------------------------------ Monitoreo ---------------------------------
ver_errores() {
    # ver_errores [cantidad]
    local n="${1:-30}"
    es_numero "$n" || { error "Cantidad inválida: '$n'"; return 1; }
    command -v journalctl >/dev/null 2>&1 || { error "journalctl no disponible."; return 1; }
    info "Últimos $n mensajes de error (prioridad err o superior):"
    journalctl -p err -n "$n" --no-pager
}

ssh_fallidos() {
    # Intentos de acceso SSH fallidos, agrupados por IP
    info "Intentos SSH fallidos por IP (top 10):"
    local datos=""
    if [ -f /var/log/auth.log ]; then
        datos="$(grep -E 'Failed password|Invalid user' /var/log/auth.log 2>/dev/null)"
    elif command -v journalctl >/dev/null 2>&1; then
        datos="$(journalctl -u ssh -u sshd --no-pager 2>/dev/null | grep -E 'Failed password|Invalid user')"
    fi

    if [ -z "$datos" ]; then
        info "  Sin intentos fallidos registrados."
        return 0
    fi
    echo "$datos" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -rn | head -10 \
        | awk '{printf "  %5s intentos  %s\n", $1, $2}'
}

uso_sudo() {
    local n="${1:-20}"
    es_numero "$n" || { error "Cantidad inválida: '$n'"; return 1; }
    info "Últimos $n usos de sudo:"
    if [ -f /var/log/auth.log ]; then
        grep 'sudo:' /var/log/auth.log | grep 'COMMAND' | tail -n "$n"
    elif command -v journalctl >/dev/null 2>&1; then
        journalctl _COMM=sudo --no-pager -n "$n"
    else
        error "No hay fuente de logs de sudo."
        return 1
    fi
}

logs_contenedor() {
    # logs_contenedor <contenedor> [lineas]
    local nombre="${1:-}" n="${2:-50}"
    [ -z "$nombre" ] && { error "Uso: logs_contenedor <contenedor> [lineas]  (ej: dm_app, dm_db)"; return 1; }
    es_numero "$n" || { error "Cantidad inválida: '$n'"; return 1; }
    command -v docker >/dev/null 2>&1 || { error "Docker no está instalado."; return 1; }
    docker ps -a --format '{{.Names}}' | grep -qx "$nombre" || { error "No existe el contenedor '$nombre'."; return 1; }

    info "Últimas $n líneas de '$nombre':"
    docker logs --tail "$n" "$nombre" 2>&1
}

errores_scripts() {
    # Errores registrados por los scripts de administración
    info "Errores recientes en los logs de los scripts ($LOG_DIR):"
    local f hay=0
    for f in "$LOG_DIR"/*.log; do
        [ -f "$f" ] || continue
        if grep -q '\[ERROR\]' "$f"; then
            hay=1
            echo "--- $(basename "$f") ---"
            grep '\[ERROR\]' "$f" | tail -5
        fi
    done
    [ "$hay" -eq 0 ] && info "  Sin errores registrados."
    return 0
}

mostrar_resumen() {
    echo "=== Resumen de logs ($(date '+%d/%m/%Y %H:%M')) ==="
    echo "Espacio en /var/log : $(du -sh /var/log 2>/dev/null | cut -f1)"
    echo "Logs DataMiners     : $(du -sh "$LOG_DIR" 2>/dev/null | cut -f1) en $LOG_DIR"
    command -v journalctl >/dev/null 2>&1 && echo "Journal             : $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)"
    command -v journalctl >/dev/null 2>&1 && echo "Errores (24 h)      : $(journalctl -p err --since '24 hours ago' --no-pager 2>/dev/null | grep -vc '^-- ')"
    [ -f "$LOGROTATE_FILE" ] && echo "Rotación            : configurada" || echo "Rotación            : NO configurada"
    echo
    ssh_fallidos
    echo
    errores_scripts
}

seguir_log() {
    # seguir_log <archivo>
    local archivo="${1:-}"
    [ -z "$archivo" ] && { error "Uso: seguir_log <archivo>"; return 1; }
    [ -f "$archivo" ] || archivo="$LOG_DIR/$archivo"
    [ -f "$archivo" ] || { error "No existe el archivo de log."; return 1; }
    info "Siguiendo $archivo (Ctrl+C para salir)"
    tail -n 20 -f "$archivo"
}

# ------------------------------------- Ayuda ------------------------------------
mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [argumentos]

Configuración:
  configurar               Rotación (logrotate) + límite de journal (journald)
  rotar                    Fuerza la rotación ahora

Monitoreo:
  resumen                  Resumen general de logs, SSH fallidos y errores
  errores [n]              Últimos n errores del sistema (por defecto 30)
  ssh-fallidos             Intentos de acceso SSH fallidos por IP
  sudo [n]                 Últimos usos de sudo
  scripts                  Errores registrados por los scripts de administración
  contenedor <nombre> [n]  Logs de un contenedor (dm_app, dm_db)
  seguir <archivo>         Sigue un log en vivo

  ayuda                    Muestra esta ayuda
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
        configurar)    configurar_todo ;;
        rotar)         rotar_ahora ;;
        resumen)       mostrar_resumen ;;
        errores)       ver_errores "$@" ;;
        ssh-fallidos)  ssh_fallidos ;;
        sudo)          uso_sudo "$@" ;;
        scripts)       errores_scripts ;;
        contenedor)    logs_contenedor "$@" ;;
        seguir)        seguir_log "$@" ;;
        *)             error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
