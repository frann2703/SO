#!/usr/bin/env bash
# =============================================================================
# backups.sh - Copias de seguridad automatizadas y organizadas
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Script de backups (Administración de SO)
# Consigna : Crear un script que permita realizar copias de seguridad de forma
#            automatizada y organizada.
#
# Qué hace:
#   - Respalda archivos/directorios importantes (tar.gz)
#   - Respalda la base de datos MySQL que corre en Docker (mysqldump.gz)
#   - Genera un checksum SHA-256 por cada backup
#   - Aplica retención (borra backups viejos)
#   - Envía los backups al servidor de respaldo (rsync por SSH)
#   - Instala la tarea automática en cron
#
# Uso:
#   sudo ./backups.sh <comando> [argumentos]
#   sudo ./backups.sh ayuda
#
# Variables configurables (export antes de ejecutar):
#   BACKUP_DIR, ORIGENES, RETENCION_DIAS, ENV_FILE, DB_CONTENEDOR,
#   REMOTO_HOST, REMOTO_USUARIO, REMOTO_DIR
# =============================================================================

set -u
umask 077   # los backups solo los puede leer root

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/backups.log}"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/dataminers}"
ORIGENES="${ORIGENES:-/etc /srv/app /home}"          # separados por espacio
RETENCION_DIAS="${RETENCION_DIAS:-7}"

ENV_FILE="${ENV_FILE:-/srv/app/docker/.env}"         # credenciales de la base
DB_CONTENEDOR="${DB_CONTENEDOR:-dm_db}"

REMOTO_HOST="${REMOTO_HOST:-}"                       # vacío = no enviar
REMOTO_USUARIO="${REMOTO_USUARIO:-respaldo}"
REMOTO_DIR="${REMOTO_DIR:-/srv/respaldos}"

CRON_FILE="${CRON_FILE:-/etc/cron.d/dataminers-backup}"
CRON_HORARIO="${CRON_HORARIO:-30 2 * * *}"           # todos los días 02:30

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

marca_tiempo() { date +%Y%m%d_%H%M%S; }

leer_env() {
    # leer_env <VARIABLE>  -> valor desde ENV_FILE
    local clave="$1" valor
    [ -f "$ENV_FILE" ] || return 1
    valor="$(grep -E "^${clave}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)"
    valor="${valor%\"}"; valor="${valor#\"}"
    printf '%s' "$valor"
}

crear_checksum() {
    # crear_checksum <archivo>
    local archivo="$1"
    ( cd "$(dirname "$archivo")" && sha256sum "$(basename "$archivo")" > "$(basename "$archivo").sha256" )
}

# ---------------------------------- Backups -----------------------------------
backup_archivos() {
    mkdir -p "$BACKUP_DIR" || { error "No se pudo crear $BACKUP_DIR"; return 1; }

    local existentes=() origen
    for origen in $ORIGENES; do
        if [ -e "$origen" ]; then
            existentes+=("$origen")
        else
            aviso "Origen inexistente, se omite: $origen"
        fi
    done
    [ "${#existentes[@]}" -eq 0 ] && { error "No hay orígenes válidos para respaldar."; return 1; }

    local destino="$BACKUP_DIR/archivos_$(marca_tiempo).tar.gz"
    info "Respaldando: ${existentes[*]}"

    tar -czf "$destino" "${existentes[@]}" 2>/dev/null
    local rc=$?
    # rc=1 significa "algún archivo cambió mientras se leía": no es fatal
    if [ "$rc" -gt 1 ]; then
        error "Falló el backup de archivos (código $rc)."
        rm -f "$destino"
        return 1
    fi

    crear_checksum "$destino"
    info "Backup de archivos listo: $destino ($(du -h "$destino" | cut -f1))"
}

backup_db() {
    mkdir -p "$BACKUP_DIR" || { error "No se pudo crear $BACKUP_DIR"; return 1; }

    command -v docker >/dev/null 2>&1 || { error "Docker no está instalado: no se puede respaldar la base."; return 1; }
    docker ps --format '{{.Names}}' | grep -qx "$DB_CONTENEDOR" \
        || { error "El contenedor '$DB_CONTENEDOR' no está en ejecución."; return 1; }

    local pass db
    pass="$(leer_env MYSQL_ROOT_PASSWORD)"
    db="$(leer_env MYSQL_DATABASE)"; db="${db:-dataminers}"
    [ -z "$pass" ] && { error "No se encontró MYSQL_ROOT_PASSWORD en $ENV_FILE"; return 1; }

    local destino="$BACKUP_DIR/db_${db}_$(marca_tiempo).sql.gz"
    info "Respaldando la base '$db' desde el contenedor '$DB_CONTENEDOR'"

    # La contraseña viaja por variable de entorno (no queda en la lista de procesos)
    MYSQL_PWD="$pass" docker exec -e MYSQL_PWD "$DB_CONTENEDOR" \
        mysqldump -uroot --single-transaction --routines --triggers --no-tablespaces "$db" 2>/dev/null \
        | gzip > "$destino"
    local rc=("${PIPESTATUS[@]}")

    if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ] || ! gzip -t "$destino" 2>/dev/null; then
        error "Falló el backup de la base de datos."
        rm -f "$destino"
        return 1
    fi

    crear_checksum "$destino"
    info "Backup de base de datos listo: $destino ($(du -h "$destino" | cut -f1))"
}

backup_completo() {
    local fallos=0
    backup_archivos || fallos=$((fallos + 1))
    backup_db       || fallos=$((fallos + 1))
    limpiar_backups || fallos=$((fallos + 1))

    if [ -n "$REMOTO_HOST" ]; then
        enviar_remoto || fallos=$((fallos + 1))
    else
        aviso "REMOTO_HOST no configurado: los backups quedan solo en este servidor."
    fi

    if [ "$fallos" -eq 0 ]; then
        info "Backup completo finalizado sin errores."
    else
        error "Backup completo finalizado con $fallos error(es)."
        return 1
    fi
}

# --------------------------------- Mantenimiento -------------------------------
limpiar_backups() {
    [ -d "$BACKUP_DIR" ] || return 0
    local cantidad
    cantidad="$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.sql.gz' -o -name '*.sha256' \) \
                -mtime +"$RETENCION_DIAS" | wc -l)"
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.sql.gz' -o -name '*.sha256' \) \
        -mtime +"$RETENCION_DIAS" -delete
    info "Retención ${RETENCION_DIAS} días: $cantidad archivo(s) viejo(s) eliminado(s)."
}

verificar_backup() {
    # verificar_backup <archivo>
    local archivo="${1:-}"
    [ -z "$archivo" ] && { error "Uso: verificar_backup <archivo>"; return 1; }
    [ -f "$archivo" ] || { error "No existe: $archivo"; return 1; }
    [ -f "$archivo.sha256" ] || { error "Falta el checksum: $archivo.sha256"; return 1; }

    if ( cd "$(dirname "$archivo")" && sha256sum -c --quiet "$(basename "$archivo").sha256" ); then
        info "Checksum correcto: $(basename "$archivo")"
    else
        error "Checksum INCORRECTO: $(basename "$archivo") (archivo corrupto o modificado)"
        return 1
    fi
}

verificar_todos() {
    local f fallos=0 total=0
    for f in "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.sql.gz; do
        [ -f "$f" ] || continue
        total=$((total + 1))
        verificar_backup "$f" || fallos=$((fallos + 1))
    done
    info "Verificación: $total backup(s), $fallos con error."
    [ "$fallos" -eq 0 ]
}

listar_backups() {
    [ -d "$BACKUP_DIR" ] || { aviso "Todavía no existe $BACKUP_DIR."; return 0; }
    info "Backups en $BACKUP_DIR:"
    local f
    # shellcheck disable=SC2012
    for f in $(ls -1t "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.sql.gz 2>/dev/null); do
        printf "  %-8s %s  %s\n" "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%d/%m/%Y %H:%M')" "$(basename "$f")"
    done
    info "Espacio usado: $(du -sh "$BACKUP_DIR" | cut -f1)"
}

# ---------------------------------- Remoto -------------------------------------
enviar_remoto() {
    [ -z "$REMOTO_HOST" ] && { error "Definir REMOTO_HOST (IP o nombre del servidor de respaldo)."; return 1; }
    command -v rsync >/dev/null 2>&1 || { error "rsync no está instalado."; return 1; }

    info "Enviando backups a ${REMOTO_USUARIO}@${REMOTO_HOST}:${REMOTO_DIR}"
    # Sin --delete: la retención del servidor de respaldo es independiente
    if rsync -a --partial --include='*.tar.gz' --include='*.sql.gz' --include='*.sha256' --exclude='*' \
         -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
         "$BACKUP_DIR"/ "${REMOTO_USUARIO}@${REMOTO_HOST}:${REMOTO_DIR}/"; then
        info "Envío al servidor de respaldo completado."
    else
        error "Falló el envío al servidor de respaldo (¿clave SSH instalada? ¿firewall?)."
        return 1
    fi
}

# ------------------------------------ Cron -------------------------------------
instalar_cron() {
    cat > "$CRON_FILE" <<EOF
# Backup automático DataMiners (generado por backups.sh)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$CRON_HORARIO root $SCRIPT_PATH completo >> $LOG_DIR/backups_cron.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    info "Tarea programada instalada en $CRON_FILE ($CRON_HORARIO)."
}

quitar_cron() {
    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE" && info "Tarea programada eliminada."
    else
        aviso "No hay tarea programada instalada."
    fi
}

# ------------------------------------ Ayuda ------------------------------------
mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [argumentos]

Backups:
  archivos                 Respalda los directorios de ORIGENES ($ORIGENES)
  db                       Respalda la base MySQL del contenedor $DB_CONTENEDOR
  completo                 archivos + db + limpieza + envío al servidor de respaldo

Mantenimiento:
  listar                   Lista los backups existentes
  verificar [archivo]      Verifica el checksum (sin archivo: todos)
  limpiar                  Borra backups de más de $RETENCION_DIAS días
  enviar                   Envía los backups al servidor de respaldo (REMOTO_HOST)

Automatización:
  cron-instalar            Programa el backup completo ($CRON_HORARIO)
  cron-quitar              Quita la tarea programada

  ayuda                    Muestra esta ayuda

Ejemplos:
  sudo $0 completo
  sudo REMOTO_HOST=192.168.1.50 $0 enviar
EOF
}

# ------------------------------------- Main ------------------------------------
main() {
    local comando="${1:-ayuda}"
    [ $# -gt 0 ] && shift

    case "$comando" in
        ayuda|-h|--help) mostrar_ayuda; return 0 ;;
    esac

    verificar_root || return 1

    case "$comando" in
        archivos)       backup_archivos ;;
        db)             backup_db ;;
        completo)       backup_completo ;;
        listar)         listar_backups ;;
        verificar)      if [ $# -gt 0 ]; then verificar_backup "$1"; else verificar_todos; fi ;;
        limpiar)        limpiar_backups ;;
        enviar)         enviar_remoto ;;
        cron-instalar)  instalar_cron ;;
        cron-quitar)    quitar_cron ;;
        *)              error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
