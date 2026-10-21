#!/usr/bin/env bash
# =============================================================================
# servidor_respaldo.sh - Configuración del servidor de respaldo
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Servidor de respaldo (Administración de SO)
# Consigna : Configurar un servidor destinado al almacenamiento y gestión de
#            las copias de seguridad del sistema.
#
# Se ejecuta EN EL SERVIDOR DE RESPALDO (otra máquina o VM distinta al servidor
# de la aplicación). Deja listo el equipo para recibir los backups por rsync/SSH.
#
# Qué hace:
#   - Crea el usuario 'respaldo' (sin contraseña, solo acceso por clave SSH)
#   - Crea el directorio de almacenamiento con permisos restringidos
#   - Autoriza la clave pública del servidor de la aplicación (con restricciones)
#   - Aplica retención automática con cron
#   - Verifica la integridad de los backups recibidos y muestra el estado
#
# Uso:
#   sudo ./servidor_respaldo.sh <comando> [argumentos]
#   sudo ./servidor_respaldo.sh ayuda
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/servidor_respaldo.log}"

USUARIO_RESPALDO="${USUARIO_RESPALDO:-respaldo}"
DIR_RESPALDOS="${DIR_RESPALDOS:-/srv/respaldos}"
RETENCION_DIAS="${RETENCION_DIAS:-30}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/dataminers-retencion}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

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

usuario_existe() { id "$1" >/dev/null 2>&1; }

# ----------------------------------- Instalación -------------------------------
instalar() {
    # Paquetes necesarios (solo si hay apt y faltan)
    if ! command -v rsync >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            info "Instalando rsync y openssh-server..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y rsync openssh-server >/dev/null \
                || { error "No se pudieron instalar los paquetes."; return 1; }
        else
            error "rsync no está instalado y no hay apt-get. Instalarlo manualmente."
            return 1
        fi
    fi

    # Usuario dedicado, sin contraseña (bloqueada): solo entra con clave SSH
    if usuario_existe "$USUARIO_RESPALDO"; then
        aviso "El usuario '$USUARIO_RESPALDO' ya existe."
    else
        useradd -m -s /bin/bash -c "Usuario de backups DataMiners" "$USUARIO_RESPALDO" \
            || { error "No se pudo crear el usuario '$USUARIO_RESPALDO'."; return 1; }
        passwd -l "$USUARIO_RESPALDO" >/dev/null
        info "Usuario '$USUARIO_RESPALDO' creado (contraseña bloqueada, solo clave SSH)."
    fi

    # Directorio de almacenamiento
    mkdir -p "$DIR_RESPALDOS"
    chown "$USUARIO_RESPALDO":"$USUARIO_RESPALDO" "$DIR_RESPALDOS"
    chmod 700 "$DIR_RESPALDOS"
    info "Directorio de respaldos listo: $DIR_RESPALDOS (permisos 700)."

    # Carpeta .ssh
    local home
    home="$(getent passwd "$USUARIO_RESPALDO" | cut -d: -f6)"
    mkdir -p "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    chown -R "$USUARIO_RESPALDO":"$USUARIO_RESPALDO" "$home/.ssh"
    chmod 700 "$home/.ssh"
    chmod 600 "$home/.ssh/authorized_keys"

    instalar_retencion
    info "Servidor de respaldo instalado. Siguiente paso: autorizar la clave del servidor de la app."
    info "  sudo $0 clave /ruta/id_ed25519.pub [IP_servidor_app]"
}

# ------------------------------------ Claves SSH -------------------------------
autorizar_clave() {
    # autorizar_clave <archivo.pub | "ssh-ed25519 AAAA..."> [IP_permitida]
    local origen="${1:-}" ip="${2:-}"
    [ -z "$origen" ] && { error "Uso: autorizar_clave <archivo.pub> [IP_servidor_app]"; return 1; }
    usuario_existe "$USUARIO_RESPALDO" || { error "Primero ejecutar: $0 instalar"; return 1; }

    local clave
    if [ -f "$origen" ]; then
        clave="$(head -1 "$origen")"
    else
        clave="$origen"
    fi

    if [[ ! "$clave" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+)\ [A-Za-z0-9+/=]+ ]]; then
        error "La clave pública no tiene un formato válido."
        return 1
    fi

    if [ -n "$ip" ] && [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        error "IP inválida: '$ip'"
        return 1
    fi

    local home auth prefijo
    home="$(getent passwd "$USUARIO_RESPALDO" | cut -d: -f6)"
    auth="$home/.ssh/authorized_keys"

    if grep -qF "$clave" "$auth" 2>/dev/null; then
        aviso "Esa clave ya estaba autorizada."
        return 0
    fi

    # 'restrict' desactiva reenvío de puertos, agente, X11 y pty; 'from' limita el origen
    prefijo="restrict"
    [ -n "$ip" ] && prefijo="restrict,from=\"$ip\""

    echo "$prefijo $clave" >> "$auth"
    chown "$USUARIO_RESPALDO":"$USUARIO_RESPALDO" "$auth"
    info "Clave autorizada${ip:+ solo desde $ip}."
}

# -------------------------------------- Retención ------------------------------
aplicar_retencion() {
    [ -d "$DIR_RESPALDOS" ] || { error "No existe $DIR_RESPALDOS"; return 1; }
    local cantidad
    cantidad="$(find "$DIR_RESPALDOS" -type f \( -name '*.tar.gz' -o -name '*.sql.gz' -o -name '*.sha256' \) \
                -mtime +"$RETENCION_DIAS" | wc -l)"
    find "$DIR_RESPALDOS" -type f \( -name '*.tar.gz' -o -name '*.sql.gz' -o -name '*.sha256' \) \
        -mtime +"$RETENCION_DIAS" -delete
    info "Retención ${RETENCION_DIAS} días: $cantidad archivo(s) eliminado(s)."
}

instalar_retencion() {
    cat > "$CRON_FILE" <<EOF
# Retención de backups DataMiners (generado por servidor_respaldo.sh)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 3 * * * root RETENCION_DIAS=$RETENCION_DIAS DIR_RESPALDOS=$DIR_RESPALDOS $SCRIPT_PATH retencion >> $LOG_DIR/servidor_respaldo_cron.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    info "Retención automática programada en $CRON_FILE (${RETENCION_DIAS} días)."
}

# ------------------------------------ Verificación -----------------------------
verificar_integridad() {
    [ -d "$DIR_RESPALDOS" ] || { error "No existe $DIR_RESPALDOS"; return 1; }
    local f total=0 fallos=0
    for f in "$DIR_RESPALDOS"/*.tar.gz "$DIR_RESPALDOS"/*.sql.gz; do
        [ -f "$f" ] || continue
        total=$((total + 1))
        if [ ! -f "$f.sha256" ]; then
            aviso "Sin checksum: $(basename "$f")"
            fallos=$((fallos + 1))
        elif ! ( cd "$DIR_RESPALDOS" && sha256sum -c --quiet "$(basename "$f").sha256" ); then
            error "Checksum INCORRECTO: $(basename "$f")"
            fallos=$((fallos + 1))
        fi
    done
    info "Integridad: $total backup(s) revisado(s), $fallos con problemas."
    [ "$fallos" -eq 0 ]
}

# -------------------------------------- Estado ---------------------------------
mostrar_estado() {
    echo "=== Servidor de respaldo ==="
    if usuario_existe "$USUARIO_RESPALDO"; then
        echo "Usuario          : $USUARIO_RESPALDO (existe)"
    else
        echo "Usuario          : $USUARIO_RESPALDO (NO existe, ejecutar 'instalar')"
    fi
    echo "Directorio       : $DIR_RESPALDOS"

    if [ -d "$DIR_RESPALDOS" ]; then
        echo "Backups guardados: $(find "$DIR_RESPALDOS" -type f \( -name '*.tar.gz' -o -name '*.sql.gz' \) | wc -l)"
        echo "Espacio usado    : $(du -sh "$DIR_RESPALDOS" | cut -f1)"
        echo "Espacio libre    : $(df -h --output=avail "$DIR_RESPALDOS" | tail -1 | tr -d ' ')"
        local ultimo
        ultimo="$(ls -1t "$DIR_RESPALDOS"/*.tar.gz "$DIR_RESPALDOS"/*.sql.gz 2>/dev/null | head -1)"
        echo "Último backup    : ${ultimo:+$(basename "$ultimo") ($(date -r "$ultimo" '+%d/%m/%Y %H:%M'))}"
    else
        echo "Directorio       : todavía no existe"
    fi

    local home claves=0
    if usuario_existe "$USUARIO_RESPALDO"; then
        home="$(getent passwd "$USUARIO_RESPALDO" | cut -d: -f6)"
        claves="$(grep -c '^' "$home/.ssh/authorized_keys" 2>/dev/null || echo 0)"
    fi
    echo "Claves SSH       : $claves autorizada(s)"
    echo "Retención        : ${RETENCION_DIAS} días"
    [ -f "$CRON_FILE" ] && echo "Cron retención   : activo" || echo "Cron retención   : no instalado"
}

# ------------------------------------- Ayuda -----------------------------------
mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [argumentos]   (ejecutar en el SERVIDOR DE RESPALDO)

  instalar                       Crea usuario, directorio, permisos y retención
  clave <archivo.pub> [IP]       Autoriza la clave pública del servidor de la app
                                 (opcional: solo permitir conexiones desde esa IP)
  verificar                      Revisa los checksums de todos los backups recibidos
  retencion                      Borra backups de más de $RETENCION_DIAS días
  estado                         Muestra usuario, espacio, último backup y claves
  ayuda                          Muestra esta ayuda

Flujo completo:
  1. (servidor de respaldo)  sudo $0 instalar
  2. (servidor de la app)    sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
                             (copiar el contenido de /root/.ssh/id_ed25519.pub)
  3. (servidor de respaldo)  sudo $0 clave id_ed25519.pub 192.168.1.10
  4. (servidor de la app)    sudo REMOTO_HOST=<IP_respaldo> ./backups.sh enviar
EOF
}

# -------------------------------------- Main -----------------------------------
main() {
    local comando="${1:-ayuda}"
    [ $# -gt 0 ] && shift

    case "$comando" in
        ayuda|-h|--help) mostrar_ayuda; return 0 ;;
    esac

    verificar_root || return 1

    case "$comando" in
        instalar)   instalar ;;
        clave)      autorizar_clave "$@" ;;
        verificar)  verificar_integridad ;;
        retencion)  aplicar_retencion ;;
        estado)     mostrar_estado ;;
        *)          error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
