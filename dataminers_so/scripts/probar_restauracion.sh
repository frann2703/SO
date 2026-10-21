#!/usr/bin/env bash
# =============================================================================
# probar_restauracion.sh - Prueba de restauración de backups
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Probar restauración de backup (Administración de SO)
#
# Qué hace (sin tocar los datos reales):
#   - Archivos: verifica el checksum, la integridad del tar.gz y restaura el
#     contenido en un directorio temporal; cuenta los archivos restaurados.
#   - Base de datos: verifica el checksum y el gzip, levanta un contenedor MySQL
#     TEMPORAL, importa el dump y comprueba que existan las tablas.
#   - Genera un informe con fecha para adjuntar como evidencia.
#
# Uso:
#   sudo ./probar_restauracion.sh <comando> [archivo]
#   sudo ./probar_restauracion.sh ayuda
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/restauracion.log}"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/dataminers}"
INFORME_DIR="${INFORME_DIR:-$BACKUP_DIR/informes}"
MYSQL_IMAGEN="${MYSQL_IMAGEN:-mysql:8.0}"
CONTENEDOR_PRUEBA="dm_restore_test"
ESPERA_MYSQL="${ESPERA_MYSQL:-90}"        # segundos máximos esperando a MySQL

INFORME=""
TEMP_DIR=""

# ---------------------------------- Utilidades --------------------------------
registrar() {
    local nivel="$1"; shift
    local linea
    linea="$(date '+%Y-%m-%d %H:%M:%S') [$nivel] $*"
    echo "$linea"
    [ -n "$INFORME" ] && echo "$linea" >> "$INFORME"
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

limpiar_temporales() {
    [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    if command -v docker >/dev/null 2>&1; then
        docker rm -f "$CONTENEDOR_PRUEBA" >/dev/null 2>&1
    fi
}
trap limpiar_temporales EXIT

iniciar_informe() {
    mkdir -p "$INFORME_DIR"
    INFORME="$INFORME_DIR/restauracion_$(date +%Y%m%d_%H%M%S).txt"
    : > "$INFORME"
    chmod 600 "$INFORME"
    info "===== Prueba de restauración - $(date '+%d/%m/%Y %H:%M') - host $(hostname) ====="
}

ultimo_backup() {
    # ultimo_backup <patron>  -> el más reciente
    ls -1t "$BACKUP_DIR"/$1 2>/dev/null | head -1
}

verificar_checksum() {
    local archivo="$1"
    if [ ! -f "$archivo.sha256" ]; then
        error "Falta el checksum de $(basename "$archivo")"
        return 1
    fi
    if ( cd "$(dirname "$archivo")" && sha256sum -c --quiet "$(basename "$archivo").sha256" ); then
        info "[OK] Checksum SHA-256 correcto."
    else
        error "[FALLO] Checksum incorrecto: el backup está corrupto o fue modificado."
        return 1
    fi
}

# ------------------------------ Prueba de archivos -----------------------------
probar_archivos() {
    local archivo="${1:-$(ultimo_backup 'archivos_*.tar.gz')}"
    [ -z "$archivo" ] && { error "No hay backups de archivos en $BACKUP_DIR."; return 1; }
    [ -f "$archivo" ] || { error "No existe: $archivo"; return 1; }

    info "--- Restauración de archivos: $(basename "$archivo") ($(du -h "$archivo" | cut -f1)) ---"

    verificar_checksum "$archivo" || return 1

    if tar -tzf "$archivo" >/dev/null 2>&1; then
        info "[OK] El tar.gz se puede leer completo."
    else
        error "[FALLO] El tar.gz está dañado."
        return 1
    fi

    local esperados
    esperados="$(tar -tzf "$archivo" | grep -vc '/$')"

    TEMP_DIR="$(mktemp -d /tmp/dm_restore.XXXXXX)"
    if ! tar -xzf "$archivo" -C "$TEMP_DIR" 2>/dev/null; then
        error "[FALLO] No se pudo extraer el backup."
        return 1
    fi

    local restaurados
    restaurados="$(find "$TEMP_DIR" -type f | wc -l)"
    info "Archivos en el backup: $esperados | restaurados: $restaurados"

    if [ "$esperados" -eq "$restaurados" ]; then
        info "[OK] Se restauró el 100% de los archivos en $TEMP_DIR (se borra al terminar)."
    else
        error "[FALLO] La cantidad de archivos restaurados no coincide."
        return 1
    fi

    info "Muestra del contenido restaurado:"
    find "$TEMP_DIR" -type f | head -5 | sed "s|$TEMP_DIR|  |" | while read -r l; do info "$l"; done
    info "RESULTADO ARCHIVOS: CORRECTO"
}

# ---------------------------- Prueba de base de datos --------------------------
probar_db() {
    local archivo="${1:-$(ultimo_backup 'db_*.sql.gz')}"
    [ -z "$archivo" ] && { error "No hay backups de base de datos en $BACKUP_DIR."; return 1; }
    [ -f "$archivo" ] || { error "No existe: $archivo"; return 1; }

    info "--- Restauración de base de datos: $(basename "$archivo") ($(du -h "$archivo" | cut -f1)) ---"

    verificar_checksum "$archivo" || return 1

    if gzip -t "$archivo" 2>/dev/null; then
        info "[OK] El archivo gzip está íntegro."
    else
        error "[FALLO] El archivo gzip está dañado."
        return 1
    fi

    if ! zcat "$archivo" | head -50 | grep -qiE 'CREATE TABLE|INSERT INTO|(MySQL|MariaDB) dump'; then
        error "[FALLO] El contenido no parece un dump de MySQL."
        return 1
    fi
    info "[OK] El contenido es un dump de MySQL."

    if ! command -v docker >/dev/null 2>&1; then
        aviso "Docker no está instalado: se omite la restauración real en MySQL temporal."
        info "RESULTADO BASE DE DATOS: PARCIAL (integridad verificada, sin restaurar)"
        return 0
    fi

    local pass db tablas_dump
    pass="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
    db="$(basename "$archivo" | sed -E 's/^db_(.*)_[0-9]{8}_[0-9]{6}\.sql\.gz$/\1/')"
    tablas_dump="$(zcat "$archivo" | grep -c '^CREATE TABLE')"

    info "Levantando MySQL temporal ($MYSQL_IMAGEN)..."
    if ! docker run -d --name "$CONTENEDOR_PRUEBA" -e MYSQL_ROOT_PASSWORD="$pass" \
            -e MYSQL_DATABASE="$db" "$MYSQL_IMAGEN" >/dev/null 2>&1; then
        error "[FALLO] No se pudo iniciar el contenedor temporal."
        return 1
    fi

    local i=0
    until MYSQL_PWD="$pass" docker exec -e MYSQL_PWD "$CONTENEDOR_PRUEBA" mysqladmin ping -h127.0.0.1 -uroot --silent >/dev/null 2>&1; do
        i=$((i + 2)); sleep 2
        if [ "$i" -ge "$ESPERA_MYSQL" ]; then
            error "[FALLO] MySQL temporal no estuvo listo en ${ESPERA_MYSQL}s."
            return 1
        fi
    done

    if zcat "$archivo" | MYSQL_PWD="$pass" docker exec -i -e MYSQL_PWD "$CONTENEDOR_PRUEBA" mysql -uroot "$db" 2>/dev/null; then
        info "[OK] El dump se importó sin errores."
    else
        error "[FALLO] Error al importar el dump."
        return 1
    fi

    local tablas_restauradas filas
    tablas_restauradas="$(MYSQL_PWD="$pass" docker exec -e MYSQL_PWD "$CONTENEDOR_PRUEBA" mysql -uroot -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null)"
    filas="$(MYSQL_PWD="$pass" docker exec -e MYSQL_PWD "$CONTENEDOR_PRUEBA" mysql -uroot -N -e \
        "SELECT COALESCE(SUM(table_rows),0) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null)"

    info "Tablas en el dump: $tablas_dump | restauradas: $tablas_restauradas | filas aprox.: $filas"

    if [ "${tablas_restauradas:-0}" -eq "$tablas_dump" ] && [ "$tablas_dump" -gt 0 ]; then
        info "RESULTADO BASE DE DATOS: CORRECTO"
    else
        error "RESULTADO BASE DE DATOS: FALLO (no coinciden las tablas)"
        return 1
    fi
}

probar_todo() {
    local fallos=0
    probar_archivos || fallos=$((fallos + 1))
    probar_db       || fallos=$((fallos + 1))

    if [ "$fallos" -eq 0 ]; then
        info "===== PRUEBA GLOBAL: CORRECTA ====="
    else
        error "===== PRUEBA GLOBAL: $fallos fallo(s) ====="
        return 1
    fi
}

mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [archivo]

  archivos [backup.tar.gz]   Prueba la restauración de archivos (por defecto el último)
  db [backup.sql.gz]         Prueba la restauración de la base en un MySQL temporal
  todo                       Ejecuta ambas pruebas con los últimos backups
  informes                   Lista los informes generados
  ayuda                      Muestra esta ayuda

Los informes quedan en: $INFORME_DIR
EOF
}

main() {
    local comando="${1:-ayuda}"
    [ $# -gt 0 ] && shift

    case "$comando" in
        ayuda|-h|--help) mostrar_ayuda; return 0 ;;
    esac

    verificar_root || return 1

    case "$comando" in
        archivos) iniciar_informe; probar_archivos "$@" ;;
        db)       iniciar_informe; probar_db "$@" ;;
        todo)     iniciar_informe; probar_todo ;;
        informes) ls -lt "$INFORME_DIR" 2>/dev/null || aviso "Todavía no hay informes." ;;
        *)        error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
    local rc=$?
    [ -n "$INFORME" ] && info "Informe guardado en: $INFORME"
    return $rc
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
