#!/usr/bin/env bash
# =============================================================================
# basedatos.sh - Configuración y preparación de la base de datos
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Script de base de datos (Administración de SO)
#
# Qué hace:
#   - Crea la base de datos (utf8mb4) y el usuario de la aplicación con los
#     MÍNIMOS privilegios (SELECT, INSERT, UPDATE, DELETE; sin DROP ni ALTER)
#   - Importa el esquema inicial (schema.sql)
#   - Comprueba el estado, las tablas y la conexión del usuario de la app
#
# Funciona con MySQL dentro de Docker (por defecto) o instalado en el servidor.
# Las credenciales se leen del archivo .env (nunca van escritas en el script).
#
# Uso:
#   sudo ./basedatos.sh <comando> [argumentos]
#   sudo ./basedatos.sh ayuda
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/basedatos.log}"

MODO="${MODO:-docker}"                                   # docker | local
DB_CONTENEDOR="${DB_CONTENEDOR:-dm_db}"
ENV_FILE="${ENV_FILE:-/srv/app/docker/.env}"
SCHEMA_FILE="${SCHEMA_FILE:-/srv/app/docker/initdb/01_schema.sql}"

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

leer_env() {
    local clave="$1" valor
    [ -f "$ENV_FILE" ] || return 1
    valor="$(grep -E "^${clave}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)"
    valor="${valor%\"}"; valor="${valor#\"}"
    printf '%s' "$valor"
}

# Identificadores (base, usuario): solo letras, números y guion bajo
validar_identificador() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]{0,31}$ ]] || {
        error "Identificador inválido: '$1' (letras, números y _; máx. 32)."
        return 1
    }
}

# Contraseña: sin comillas ni barras, para no romper el SQL
validar_password() {
    [ "${#1}" -ge 12 ] || { error "La contraseña debe tener al menos 12 caracteres."; return 1; }
    [[ "$1" =~ ^[A-Za-z0-9_@%+=.,:#!-]+$ ]] || {
        error "La contraseña tiene caracteres no permitidos (usar letras, números y _@%+=.,:#!-)."
        return 1
    }
}

mysql_root() {
    # mysql_root [argumentos de mysql]  (lee SQL por stdin si hace falta)
    local pass
    pass="$(leer_env MYSQL_ROOT_PASSWORD)"
    [ -z "$pass" ] && { error "Falta MYSQL_ROOT_PASSWORD en $ENV_FILE"; return 1; }

    if [ "$MODO" = "docker" ]; then
        MYSQL_PWD="$pass" docker exec -i -e MYSQL_PWD "$DB_CONTENEDOR" mysql -uroot "$@"
    else
        MYSQL_PWD="$pass" mysql -uroot "$@"
    fi
}

verificar_motor() {
    if [ "$MODO" = "docker" ]; then
        command -v docker >/dev/null 2>&1 || { error "Docker no está instalado."; return 1; }
        docker ps --format '{{.Names}}' | grep -qx "$DB_CONTENEDOR" \
            || { error "El contenedor '$DB_CONTENEDOR' no está en ejecución (docker compose up -d)."; return 1; }
    else
        command -v mysql >/dev/null 2>&1 || { error "El cliente mysql no está instalado."; return 1; }
    fi
}

# --------------------------------- Base y usuario -------------------------------
crear_base() {
    local db; db="$(leer_env MYSQL_DATABASE)"; db="${db:-dataminers}"
    validar_identificador "$db" || return 1
    verificar_motor || return 1

    if mysql_root -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
        info "Base de datos '$db' lista (utf8mb4)."
    else
        error "No se pudo crear la base '$db'."
        return 1
    fi
}

crear_usuario_app() {
    local db usuario pass
    db="$(leer_env MYSQL_DATABASE)"; db="${db:-dataminers}"
    usuario="$(leer_env MYSQL_USER)"
    pass="$(leer_env MYSQL_PASSWORD)"

    [ -z "$usuario" ] || [ -z "$pass" ] && { error "Faltan MYSQL_USER y MYSQL_PASSWORD en $ENV_FILE"; return 1; }
    validar_identificador "$db"      || return 1
    validar_identificador "$usuario" || return 1
    validar_password "$pass"         || return 1
    verificar_motor || return 1

    # '%' porque desde Docker la app llega por la red interna; el puerto de MySQL no se publica
    if mysql_root <<SQL
CREATE USER IF NOT EXISTS '$usuario'@'%' IDENTIFIED BY '$pass';
ALTER USER '$usuario'@'%' IDENTIFIED BY '$pass';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$usuario'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`$db\`.* TO '$usuario'@'%';
FLUSH PRIVILEGES;
SQL
    then
        info "Usuario '$usuario' listo con privilegios SELECT/INSERT/UPDATE/DELETE sobre '$db'."
    else
        error "No se pudo crear/configurar el usuario '$usuario'."
        return 1
    fi
}

importar_sql() {
    # importar_sql [archivo.sql]
    local archivo="${1:-$SCHEMA_FILE}" db
    db="$(leer_env MYSQL_DATABASE)"; db="${db:-dataminers}"
    validar_identificador "$db" || return 1
    [ -f "$archivo" ] || { error "No existe el archivo SQL: $archivo"; return 1; }
    verificar_motor || return 1

    if mysql_root "$db" < "$archivo"; then
        info "Archivo importado en '$db': $archivo"
    else
        error "Falló la importación de $archivo"
        return 1
    fi
}

preparar_todo() {
    crear_base         || return 1
    crear_usuario_app  || return 1
    if [ -f "$SCHEMA_FILE" ]; then
        importar_sql "$SCHEMA_FILE" || return 1
    else
        aviso "No se encontró $SCHEMA_FILE: base creada sin tablas."
    fi
    info "Base de datos preparada."
    verificar_conexion
}

# ---------------------------------- Comprobaciones ------------------------------
mostrar_estado() {
    verificar_motor || return 1
    local db; db="$(leer_env MYSQL_DATABASE)"; db="${db:-dataminers}"
    validar_identificador "$db" || return 1

    echo "=== Versión ==="
    mysql_root -N -e "SELECT VERSION();"
    echo "=== Tablas en '$db' ==="
    mysql_root -t -e "SELECT table_name AS tabla, table_rows AS filas_aprox, ROUND((data_length+index_length)/1024,1) AS kb
                      FROM information_schema.tables WHERE table_schema='$db' ORDER BY table_name;"
    echo "=== Usuarios de la aplicación ==="
    mysql_root -t -e "SELECT user, host FROM mysql.user WHERE user NOT IN ('root','mysql.sys','mysql.session','mysql.infoschema','debian-sys-maint');"
}

verificar_conexion() {
    # Prueba que el usuario de la app pueda conectarse y operar (y que NO pueda borrar tablas)
    local db usuario pass
    db="$(leer_env MYSQL_DATABASE)"; db="${db:-dataminers}"
    usuario="$(leer_env MYSQL_USER)"
    pass="$(leer_env MYSQL_PASSWORD)"
    verificar_motor || return 1

    local cmd=(mysql -u"$usuario" "$db")
    [ "$MODO" = "docker" ] && cmd=(docker exec -i -e MYSQL_PWD "$DB_CONTENEDOR" mysql -u"$usuario" "$db")

    if MYSQL_PWD="$pass" "${cmd[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
        info "[OK] El usuario '$usuario' se conecta a '$db'."
    else
        error "[FALLO] El usuario '$usuario' no puede conectarse."
        return 1
    fi

    if MYSQL_PWD="$pass" "${cmd[@]}" -e "CREATE TABLE _prueba_permisos (id INT);" >/dev/null 2>&1; then
        MYSQL_PWD="$pass" "${cmd[@]}" -e "DROP TABLE _prueba_permisos;" >/dev/null 2>&1
        aviso "El usuario '$usuario' puede crear tablas: tiene más privilegios de los necesarios."
    else
        info "[OK] El usuario '$usuario' NO puede crear/borrar tablas (mínimo privilegio)."
    fi
}

# ------------------------------------- Ayuda ------------------------------------
mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [argumentos]

  preparar                 Crea base + usuario de la app + importa el esquema + verifica
  crear-base               Crea la base de datos (utf8mb4)
  crear-usuario            Crea el usuario de la app con privilegios mínimos
  importar [archivo.sql]   Importa un SQL (por defecto: $SCHEMA_FILE)
  estado                   Muestra versión, tablas y usuarios
  verificar                Prueba la conexión del usuario de la app

Modo: MODO=$MODO (docker | local)  |  Credenciales: $ENV_FILE
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
        preparar)       preparar_todo ;;
        crear-base)     crear_base ;;
        crear-usuario)  crear_usuario_app ;;
        importar)       importar_sql "$@" ;;
        estado)         mostrar_estado ;;
        verificar)      verificar_conexion ;;
        *)              error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
