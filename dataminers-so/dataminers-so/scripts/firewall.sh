#!/usr/bin/env bash
# =============================================================================
# firewall.sh - Reglas de firewall (UFW)
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Script de firewall (Administración de SO)
# Consigna : Configurar mediante scripts las reglas de firewall necesarias para
#            permitir únicamente las conexiones requeridas.
#
# Política: se BLOQUEA todo lo entrante y solo se permite lo necesario:
#   - SSH (con límite de intentos para frenar fuerza bruta)
#   - HTTP/HTTPS para la aplicación
#   - MySQL (3306) NO se abre: solo se accede desde la red interna de Docker
#
# Seguridad: antes de activar el firewall se asegura la regla de SSH, para no
# perder el acceso remoto al servidor.
#
# Uso:
#   sudo ./firewall.sh <comando> [argumentos]
#   sudo ./firewall.sh ayuda
#   DRY_RUN=1 sudo ./firewall.sh aplicar      (muestra los comandos sin ejecutarlos)
#
# Variables:
#   SSH_PUERTO (22)  SSH_DESDE (any o red ITI, ej: 192.168.1.0/24)
#   PUERTOS_PUBLICOS ("80 443")
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/firewall.log}"

SSH_PUERTO="${SSH_PUERTO:-22}"
SSH_DESDE="${SSH_DESDE:-any}"                   # restringir a la red del ITI es lo ideal
PUERTOS_PUBLICOS="${PUERTOS_PUBLICOS:-80 443}"  # puertos abiertos a todos (tcp)
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

ejecutar() {
    # Ejecuta el comando o, en simulacro, solo lo muestra
    if [ "$DRY_RUN" = "1" ]; then
        echo "  [SIMULACRO] $*"
        return 0
    fi
    "$@"
}

validar_puerto() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

verificar_ufw() {
    if [ "$DRY_RUN" = "1" ]; then return 0; fi
    if ! command -v ufw >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            info "Instalando ufw..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y ufw >/dev/null \
                || { error "No se pudo instalar ufw."; return 1; }
        else
            error "ufw no está instalado."
            return 1
        fi
    fi
}

puerto_ssh_en_uso() {
    # Mejor esfuerzo: puerto configurado en sshd
    if command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null | awk '/^port / {print $2; exit}'
    fi
}

# --------------------------------- Aplicar reglas -------------------------------
aplicar_reglas() {
    validar_puerto "$SSH_PUERTO" || { error "SSH_PUERTO inválido: '$SSH_PUERTO'"; return 1; }

    if [ "$SSH_DESDE" != "any" ] && [[ ! "$SSH_DESDE" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
        error "SSH_DESDE inválido: '$SSH_DESDE' (usar 'any' o una IP/red, ej: 192.168.1.0/24)"
        return 1
    fi

    local p
    for p in $PUERTOS_PUBLICOS; do
        validar_puerto "$p" || { error "Puerto público inválido: '$p'"; return 1; }
    done

    verificar_ufw || return 1

    local en_uso
    en_uso="$(puerto_ssh_en_uso)"
    if [ -n "$en_uso" ] && [ "$en_uso" != "$SSH_PUERTO" ]; then
        error "sshd escucha en el puerto $en_uso pero SSH_PUERTO=$SSH_PUERTO. Corregir para no perder el acceso."
        return 1
    fi

    info "Aplicando política de firewall..."
    [ "$DRY_RUN" = "1" ] && info "Modo SIMULACRO: no se cambia nada."

    ejecutar ufw --force reset >/dev/null
    ejecutar ufw default deny incoming
    ejecutar ufw default allow outgoing
    ejecutar ufw logging low

    # 1) SSH primero (con límite: 6 conexiones en 30 s desde una misma IP)
    if [ "$SSH_DESDE" = "any" ]; then
        ejecutar ufw limit "$SSH_PUERTO"/tcp comment 'SSH con limite'
    else
        ejecutar ufw limit from "$SSH_DESDE" to any port "$SSH_PUERTO" proto tcp comment 'SSH desde red permitida'
    fi
    info "SSH permitido en $SSH_PUERTO/tcp desde $SSH_DESDE (con límite de intentos)."

    # 2) Puertos públicos de la aplicación
    for p in $PUERTOS_PUBLICOS; do
        ejecutar ufw allow "$p"/tcp comment 'Aplicacion web'
        info "Puerto $p/tcp permitido."
    done

    # 3) Todo lo demás (incluido MySQL 3306) queda bloqueado por la política por defecto
    info "MySQL (3306) y el resto de puertos entrantes: BLOQUEADOS."

    ejecutar ufw --force enable
    info "Firewall activado."
    aviso "Docker publica puertos saltándose UFW: no publicar el puerto de MySQL en docker-compose."
}

# ---------------------------------- Reglas manuales -----------------------------
agregar_regla() {
    # agregar_regla <puerto> [tcp|udp] [desde]
    local puerto="${1:-}" proto="${2:-tcp}" desde="${3:-any}"
    [ -z "$puerto" ] && { error "Uso: agregar_regla <puerto> [tcp|udp] [desde]"; return 1; }
    validar_puerto "$puerto"  || { error "Puerto inválido: '$puerto'"; return 1; }
    [[ "$proto" =~ ^(tcp|udp)$ ]] || { error "Protocolo inválido: '$proto'"; return 1; }
    verificar_ufw || return 1

    if [ "$desde" = "any" ]; then
        ejecutar ufw allow "$puerto"/"$proto"
    else
        ejecutar ufw allow from "$desde" to any port "$puerto" proto "$proto"
    fi
    info "Regla agregada: $puerto/$proto desde $desde."
}

quitar_regla() {
    # quitar_regla <puerto> [tcp|udp]
    local puerto="${1:-}" proto="${2:-tcp}"
    [ -z "$puerto" ] && { error "Uso: quitar_regla <puerto> [tcp|udp]"; return 1; }
    validar_puerto "$puerto" || { error "Puerto inválido: '$puerto'"; return 1; }
    [ "$puerto" = "$SSH_PUERTO" ] && aviso "Estás quitando la regla de SSH ($SSH_PUERTO): podrías perder el acceso remoto."
    verificar_ufw || return 1

    ejecutar ufw --force delete allow "$puerto"/"$proto"
    info "Regla eliminada: $puerto/$proto."
}

mostrar_estado() {
    verificar_ufw || return 1
    ufw status verbose
}

desactivar() {
    verificar_ufw || return 1
    aviso "Se desactiva el firewall: el servidor queda sin filtrado."
    ejecutar ufw disable
}

# ------------------------------------- Ayuda ------------------------------------
mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [argumentos]

  aplicar                          Aplica la política completa (deny entrante + SSH + web)
  estado                           Muestra las reglas activas
  agregar <puerto> [proto] [desde] Abre un puerto (ej: agregar 8080 tcp 192.168.1.0/24)
  quitar <puerto> [proto]          Cierra un puerto
  desactivar                       Desactiva el firewall
  ayuda                            Muestra esta ayuda

Valores actuales: SSH_PUERTO=$SSH_PUERTO  SSH_DESDE=$SSH_DESDE  PUERTOS_PUBLICOS="$PUERTOS_PUBLICOS"

Ejemplos:
  sudo DRY_RUN=1 $0 aplicar
  sudo SSH_DESDE=192.168.1.0/24 $0 aplicar
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
        aplicar)     aplicar_reglas ;;
        estado)      mostrar_estado ;;
        agregar)     agregar_regla "$@" ;;
        quitar)      quitar_regla "$@" ;;
        desactivar)  desactivar ;;
        *)           error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
