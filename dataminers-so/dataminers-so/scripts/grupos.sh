#!/usr/bin/env bash
# =============================================================================
# grupos.sh - Gestión automatizada de grupos del sistema
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Script de grupos (Administración de SO)
# Consigna : Automatizar la creación y administración de grupos y la asignación
#            de usuarios y permisos correspondientes.
#
# Qué hace:
#   - Crear y eliminar grupos
#   - Agregar y quitar usuarios de un grupo
#   - Asignar un grupo y permisos a un directorio
#   - Listar grupos y sus miembros
#   - Crear los grupos base del proyecto
#
# Uso:
#   sudo ./grupos.sh <comando> [argumentos]
#   sudo ./grupos.sh ayuda
#
# Modularidad: el archivo se puede ejecutar solo o cargar desde otro script
# con "source grupos.sh" para reutilizar las funciones.
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/grupos.log}"

# Grupos base del proyecto (nombre:descripción). Editar según la necesidad.
GRUPOS_BASE=(
    "dm_admin:Administradores del servidor"
    "dm_dev:Desarrolladores de la aplicación"
    "dm_backup:Responsables de los respaldos"
    "dm_ciber:Equipo de ciberseguridad"
)

# ---------------------------------- Utilidades --------------------------------
registrar() {
    # registrar <NIVEL> <mensaje>
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

# Nombre válido: empieza con letra o guion bajo, luego letras, números, _ o -
validar_nombre() {
    local nombre="$1"
    if [[ ! "$nombre" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        error "Nombre inválido: '$nombre' (minúsculas, números, _ o -, máx. 32 caracteres)."
        return 1
    fi
}

grupo_existe()   { getent group "$1" >/dev/null 2>&1; }
usuario_existe() { id "$1" >/dev/null 2>&1; }

# ----------------------------------- Grupos -----------------------------------
crear_grupo() {
    # crear_grupo <grupo>
    local grupo="${1:-}"
    [ -z "$grupo" ] && { error "Uso: crear_grupo <grupo>"; return 1; }
    validar_nombre "$grupo" || return 1

    if grupo_existe "$grupo"; then
        aviso "El grupo '$grupo' ya existe. No se realizan cambios."
        return 0
    fi

    if groupadd "$grupo"; then
        info "Grupo '$grupo' creado correctamente."
    else
        error "No se pudo crear el grupo '$grupo'."
        return 1
    fi
}

eliminar_grupo() {
    # eliminar_grupo <grupo>
    local grupo="${1:-}"
    [ -z "$grupo" ] && { error "Uso: eliminar_grupo <grupo>"; return 1; }

    if ! grupo_existe "$grupo"; then
        error "El grupo '$grupo' no existe."
        return 1
    fi

    # groupdel falla si el grupo es el grupo primario de algún usuario
    if groupdel "$grupo"; then
        info "Grupo '$grupo' eliminado."
    else
        error "No se pudo eliminar '$grupo' (¿es grupo primario de algún usuario?)."
        return 1
    fi
}

# ------------------------------- Miembros de grupo -----------------------------
agregar_usuario() {
    # agregar_usuario <usuario> <grupo>
    local usuario="${1:-}" grupo="${2:-}"
    [ -z "$usuario" ] || [ -z "$grupo" ] && { error "Uso: agregar_usuario <usuario> <grupo>"; return 1; }

    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }
    grupo_existe "$grupo"     || { error "El grupo '$grupo' no existe."; return 1; }

    if id -nG "$usuario" | tr ' ' '\n' | grep -qx "$grupo"; then
        aviso "'$usuario' ya pertenece a '$grupo'."
        return 0
    fi

    # -a evita pisar los demás grupos del usuario
    if usermod -aG "$grupo" "$usuario"; then
        info "Usuario '$usuario' agregado al grupo '$grupo'."
    else
        error "No se pudo agregar '$usuario' a '$grupo'."
        return 1
    fi
}

quitar_usuario() {
    # quitar_usuario <usuario> <grupo>
    local usuario="${1:-}" grupo="${2:-}"
    [ -z "$usuario" ] || [ -z "$grupo" ] && { error "Uso: quitar_usuario <usuario> <grupo>"; return 1; }

    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }
    grupo_existe "$grupo"     || { error "El grupo '$grupo' no existe."; return 1; }

    if ! id -nG "$usuario" | tr ' ' '\n' | grep -qx "$grupo"; then
        aviso "'$usuario' no pertenece a '$grupo'."
        return 0
    fi

    if gpasswd -d "$usuario" "$grupo" >/dev/null; then
        info "Usuario '$usuario' quitado del grupo '$grupo'."
    else
        error "No se pudo quitar '$usuario' de '$grupo'."
        return 1
    fi
}

# ---------------------------------- Permisos ----------------------------------
asignar_permisos() {
    # asignar_permisos <directorio> <grupo> [modo]   (modo por defecto: 2770)
    local dir="${1:-}" grupo="${2:-}" modo="${3:-2770}"
    [ -z "$dir" ] || [ -z "$grupo" ] && { error "Uso: asignar_permisos <directorio> <grupo> [modo]"; return 1; }

    [ -d "$dir" ]             || { error "El directorio '$dir' no existe."; return 1; }
    grupo_existe "$grupo"     || { error "El grupo '$grupo' no existe."; return 1; }
    [[ "$modo" =~ ^[0-7]{3,4}$ ]] || { error "Modo inválido: '$modo'."; return 1; }

    # El bit setgid (2xxx) hace que los archivos nuevos hereden el grupo
    if chgrp "$grupo" "$dir" && chmod "$modo" "$dir"; then
        info "Directorio '$dir': grupo '$grupo', permisos $modo."
    else
        error "No se pudieron asignar los permisos en '$dir'."
        return 1
    fi
}

# ---------------------------------- Consultas ---------------------------------
listar_grupos() {
    # Lista los grupos de usuarios normales (GID >= 1000), excepto 'nogroup'
    info "Grupos de usuario (GID >= 1000):"
    getent group | awk -F: '$3 >= 1000 && $1 != "nogroup" { printf "  %-20s GID %-6s\n", $1, $3 }'
}

listar_miembros() {
    # listar_miembros <grupo>
    local grupo="${1:-}"
    [ -z "$grupo" ] && { error "Uso: listar_miembros <grupo>"; return 1; }
    grupo_existe "$grupo" || { error "El grupo '$grupo' no existe."; return 1; }

    local miembros
    miembros="$(getent group "$grupo" | cut -d: -f4)"
    if [ -z "$miembros" ]; then
        info "El grupo '$grupo' no tiene miembros secundarios."
    else
        info "Miembros de '$grupo': ${miembros//,/, }"
    fi
}

# --------------------------------- Grupos base --------------------------------
crear_grupos_base() {
    local item nombre desc fallos=0
    for item in "${GRUPOS_BASE[@]}"; do
        nombre="${item%%:*}"
        desc="${item#*:}"
        info "Grupo base: $nombre ($desc)"
        crear_grupo "$nombre" || fallos=$((fallos + 1))
    done
    [ "$fallos" -eq 0 ] || { error "$fallos grupo(s) base no se pudieron crear."; return 1; }
    info "Grupos base listos."
}

# ------------------------------------ Ayuda -----------------------------------
mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [argumentos]

Comandos:
  crear <grupo>                      Crea un grupo
  eliminar <grupo>                   Elimina un grupo
  agregar <usuario> <grupo>          Agrega un usuario a un grupo
  quitar <usuario> <grupo>           Quita un usuario de un grupo
  permisos <dir> <grupo> [modo]      Asigna grupo y permisos a un directorio (def. 2770)
  listar                             Lista los grupos de usuario
  miembros <grupo>                   Lista los miembros de un grupo
  base                               Crea los grupos base del proyecto
  ayuda                              Muestra esta ayuda

Ejemplos:
  sudo $0 crear dm_dev
  sudo $0 agregar bruno dm_dev
  sudo $0 permisos /srv/app dm_dev 2770
EOF
}

# ------------------------------------ Main ------------------------------------
main() {
    local comando="${1:-ayuda}"
    [ $# -gt 0 ] && shift

    case "$comando" in
        ayuda|-h|--help) mostrar_ayuda; return 0 ;;
    esac

    verificar_root || return 1

    case "$comando" in
        crear)     crear_grupo "$@" ;;
        eliminar)  eliminar_grupo "$@" ;;
        agregar)   agregar_usuario "$@" ;;
        quitar)    quitar_usuario "$@" ;;
        permisos)  asignar_permisos "$@" ;;
        listar)    listar_grupos ;;
        miembros)  listar_miembros "$@" ;;
        base)      crear_grupos_base ;;
        *)         error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
}

# Ejecuta main solo si el archivo se corre directamente (no si se hace "source")
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
