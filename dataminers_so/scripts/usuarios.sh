#!/usr/bin/env bash
# =============================================================================
# usuarios.sh - Gestión automatizada de usuarios del sistema
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Script de usuarios (Administración de SO)
#
# Qué hace:
#   - Altas: crea usuarios con home, shell, grupos y contraseña temporal
#   - Bajas: elimina usuarios (con opción de respaldar el home)
#   - Modificaciones: shell, comentario, grupo primario, bloqueo/desbloqueo
#   - Configuraciones: contraseña temporal con cambio obligatorio, expiración
#   - Altas masivas desde un archivo CSV
#   - Consultas: listar usuarios e información de un usuario
#
# Uso:
#   sudo ./usuarios.sh <comando> [argumentos]
#   sudo ./usuarios.sh ayuda
#
# Modularidad: el archivo se puede ejecutar solo o cargar desde otro script
# con "source usuarios.sh" para reutilizar las funciones.
# =============================================================================

set -u

# ------------------------------- Configuración -------------------------------
LOG_DIR="${LOG_DIR:-/var/log/dataminers}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/usuarios.log}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/usuarios}"

SHELL_DEFECTO="${SHELL_DEFECTO:-/bin/bash}"
GRUPO_DEFECTO=""                 # grupo secundario por defecto (vacío = ninguno)
DIAS_EXPIRACION_PASS="${DIAS_EXPIRACION_PASS:-90}"   # vigencia de la contraseña

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

usuario_existe() { id "$1" >/dev/null 2>&1; }
grupo_existe()   { getent group "$1" >/dev/null 2>&1; }

shell_valida() {
    # La shell debe figurar en /etc/shells (o ser nologin/false)
    local sh="$1"
    grep -qx "$sh" /etc/shells 2>/dev/null || [[ "$sh" == */nologin || "$sh" == */false ]]
}

generar_password() {
    # 14 caracteres aleatorios (letras y números)
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14
}

# ----------------------------------- Altas ------------------------------------
crear_usuario() {
    # crear_usuario <usuario> [comentario] [grupos_secundarios_separados_por_coma] [shell]
    local usuario="${1:-}" comentario="${2:-}" grupos="${3:-$GRUPO_DEFECTO}" shell="${4:-$SHELL_DEFECTO}"
    [ -z "$usuario" ] && { error "Uso: crear_usuario <usuario> [comentario] [grupos] [shell]"; return 1; }
    validar_nombre "$usuario" || return 1

    if usuario_existe "$usuario"; then
        aviso "El usuario '$usuario' ya existe. No se realizan cambios."
        return 0
    fi

    shell_valida "$shell" || { error "Shell no válida: '$shell'."; return 1; }

    # Verificar que los grupos secundarios existan antes de crear nada
    local g
    if [ -n "$grupos" ]; then
        IFS=',' read -ra lista <<< "$grupos"
        for g in "${lista[@]}"; do
            grupo_existe "$g" || { error "El grupo '$g' no existe. Usuario no creado."; return 1; }
        done
    fi

    local args=(-m -s "$shell")
    [ -n "$comentario" ] && args+=(-c "$comentario")
    [ -n "$grupos" ]     && args+=(-G "$grupos")

    if ! useradd "${args[@]}" "$usuario"; then
        error "No se pudo crear el usuario '$usuario'."
        return 1
    fi

    # Contraseña temporal: se muestra una sola vez y se obliga a cambiarla
    local pass
    pass="$(generar_password)"
    echo "$usuario:$pass" | chpasswd
    chage -d 0 "$usuario"                                  # cambio obligatorio al primer login
    chage -M "$DIAS_EXPIRACION_PASS" "$usuario"            # vigencia de la contraseña

    info "Usuario '$usuario' creado (shell: $shell${grupos:+, grupos: $grupos})."
    echo "    Contraseña temporal: $pass   (deberá cambiarla al iniciar sesión)"
}

crear_usuarios_csv() {
    # crear_usuarios_csv <archivo.csv>
    # Formato por línea: usuario,comentario,grupos(separados por ;),shell
    # Ejemplo:           mperez,Maria Perez,dm_dev;dm_backup,/bin/bash
    local archivo="${1:-}"
    [ -z "$archivo" ] && { error "Uso: crear_usuarios_csv <archivo.csv>"; return 1; }
    [ -f "$archivo" ]  || { error "El archivo '$archivo' no existe."; return 1; }

    local usuario comentario grupos shell fallos=0 total=0
    while IFS=',' read -r usuario comentario grupos shell; do
        # Ignorar líneas vacías y comentarios
        [[ -z "$usuario" || "$usuario" == \#* ]] && continue
        total=$((total + 1))
        crear_usuario "$usuario" "$comentario" "${grupos//;/,}" "${shell:-$SHELL_DEFECTO}" \
            || fallos=$((fallos + 1))
    done < "$archivo"

    info "Alta masiva finalizada: $total procesado(s), $fallos con error."
    [ "$fallos" -eq 0 ]
}

# ----------------------------------- Bajas ------------------------------------
eliminar_usuario() {
    # eliminar_usuario <usuario> [--sin-backup]
    local usuario="${1:-}" opcion="${2:-}"
    [ -z "$usuario" ] && { error "Uso: eliminar_usuario <usuario> [--sin-backup]"; return 1; }

    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }
    [ "$usuario" = "root" ]   && { error "No se puede eliminar al usuario root."; return 1; }

    local home
    home="$(getent passwd "$usuario" | cut -d: -f6)"

    # Respaldar el home antes de borrarlo
    if [ "$opcion" != "--sin-backup" ] && [ -d "$home" ]; then
        mkdir -p "$BACKUP_DIR"
        local destino="$BACKUP_DIR/${usuario}_$(date +%Y%m%d_%H%M%S).tar.gz"
        if tar -czf "$destino" -C "$(dirname "$home")" "$(basename "$home")" 2>/dev/null; then
            info "Backup del home guardado en $destino"
        else
            error "Falló el backup del home. Usuario no eliminado."
            return 1
        fi
    fi

    # Cerrar procesos activos del usuario para poder eliminarlo
    pkill -KILL -u "$usuario" 2>/dev/null

    if userdel -r "$usuario" 2>/dev/null; then
        info "Usuario '$usuario' eliminado."
    else
        error "No se pudo eliminar al usuario '$usuario'."
        return 1
    fi
}

# ------------------------------- Modificaciones -------------------------------
modificar_shell() {
    # modificar_shell <usuario> <shell>
    local usuario="${1:-}" shell="${2:-}"
    [ -z "$usuario" ] || [ -z "$shell" ] && { error "Uso: modificar_shell <usuario> <shell>"; return 1; }
    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }
    shell_valida "$shell"     || { error "Shell no válida: '$shell'."; return 1; }

    if usermod -s "$shell" "$usuario"; then
        info "Shell de '$usuario' cambiada a $shell."
    else
        error "No se pudo cambiar la shell de '$usuario'."
        return 1
    fi
}

modificar_comentario() {
    # modificar_comentario <usuario> <comentario>
    local usuario="${1:-}" comentario="${2:-}"
    [ -z "$usuario" ] || [ -z "$comentario" ] && { error "Uso: modificar_comentario <usuario> <comentario>"; return 1; }
    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }

    if usermod -c "$comentario" "$usuario"; then
        info "Comentario de '$usuario' actualizado."
    else
        error "No se pudo actualizar el comentario de '$usuario'."
        return 1
    fi
}

modificar_grupo_primario() {
    # modificar_grupo_primario <usuario> <grupo>
    local usuario="${1:-}" grupo="${2:-}"
    [ -z "$usuario" ] || [ -z "$grupo" ] && { error "Uso: modificar_grupo_primario <usuario> <grupo>"; return 1; }
    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }
    grupo_existe "$grupo"     || { error "El grupo '$grupo' no existe."; return 1; }

    if usermod -g "$grupo" "$usuario"; then
        info "Grupo primario de '$usuario' cambiado a '$grupo'."
    else
        error "No se pudo cambiar el grupo primario de '$usuario'."
        return 1
    fi
}

bloquear_usuario() {
    # bloquear_usuario <usuario>   (bloquea la contraseña y vence la cuenta)
    local usuario="${1:-}"
    [ -z "$usuario" ] && { error "Uso: bloquear_usuario <usuario>"; return 1; }
    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }
    [ "$usuario" = "root" ]   && { error "No se bloquea al usuario root."; return 1; }

    if usermod -L -e 1 "$usuario"; then
        info "Usuario '$usuario' bloqueado."
    else
        error "No se pudo bloquear a '$usuario'."
        return 1
    fi
}

desbloquear_usuario() {
    # desbloquear_usuario <usuario>
    local usuario="${1:-}"
    [ -z "$usuario" ] && { error "Uso: desbloquear_usuario <usuario>"; return 1; }
    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }

    if usermod -U -e "" "$usuario"; then
        info "Usuario '$usuario' desbloqueado."
    else
        error "No se pudo desbloquear a '$usuario'."
        return 1
    fi
}

# ----------------------------- Configuración de acceso -------------------------
resetear_password() {
    # resetear_password <usuario>   (nueva contraseña temporal, cambio obligatorio)
    local usuario="${1:-}"
    [ -z "$usuario" ] && { error "Uso: resetear_password <usuario>"; return 1; }
    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }

    local pass
    pass="$(generar_password)"
    if echo "$usuario:$pass" | chpasswd && chage -d 0 "$usuario"; then
        info "Contraseña de '$usuario' restablecida."
        echo "    Contraseña temporal: $pass   (deberá cambiarla al iniciar sesión)"
    else
        error "No se pudo restablecer la contraseña de '$usuario'."
        return 1
    fi
}

configurar_expiracion() {
    # configurar_expiracion <usuario> <dias>   (días máximos de vigencia de la contraseña)
    local usuario="${1:-}" dias="${2:-$DIAS_EXPIRACION_PASS}"
    [ -z "$usuario" ] && { error "Uso: configurar_expiracion <usuario> [dias]"; return 1; }
    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }
    [[ "$dias" =~ ^[0-9]+$ ]] || { error "Días inválidos: '$dias'."; return 1; }

    if chage -M "$dias" "$usuario"; then
        info "Contraseña de '$usuario' vence cada $dias días."
    else
        error "No se pudo configurar la expiración de '$usuario'."
        return 1
    fi
}

# ---------------------------------- Consultas ---------------------------------
listar_usuarios() {
    # Usuarios normales (UID >= 1000), excepto 'nobody'
    info "Usuarios del sistema (UID >= 1000):"
    getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" { printf "  %-18s UID %-6s shell %s\n", $1, $3, $7 }'
}

info_usuario() {
    # info_usuario <usuario>
    local usuario="${1:-}"
    [ -z "$usuario" ] && { error "Uso: info_usuario <usuario>"; return 1; }
    usuario_existe "$usuario" || { error "El usuario '$usuario' no existe."; return 1; }

    local linea
    linea="$(getent passwd "$usuario")"
    echo "Usuario     : $usuario"
    echo "UID / GID   : $(id -u "$usuario") / $(id -g "$usuario")"
    echo "Comentario  : $(echo "$linea" | cut -d: -f5)"
    echo "Home        : $(echo "$linea" | cut -d: -f6)"
    echo "Shell       : $(echo "$linea" | cut -d: -f7)"
    echo "Grupos      : $(id -nG "$usuario" | tr ' ' ', ')"
    echo "Estado pass : $(passwd -S "$usuario" 2>/dev/null | awk '{print $2}') (L=bloqueada, P=activa, NP=sin pass)"
    echo "Pass vence  : $(chage -l "$usuario" | awk -F': ' '/^Password expires/ {print $2}')"
    echo "Cuenta vence: $(chage -l "$usuario" | awk -F': ' '/^Account expires/ {print $2}')"
}

# ------------------------------------ Ayuda -----------------------------------
mostrar_ayuda() {
    cat <<EOF
Uso: sudo $0 <comando> [argumentos]

Altas:
  crear <usuario> [comentario] [grupos] [shell]   Crea un usuario (grupos separados por coma)
  csv <archivo.csv>                               Alta masiva: usuario,comentario,grupo1;grupo2,shell

Bajas:
  eliminar <usuario> [--sin-backup]               Elimina un usuario (respalda su home por defecto)

Modificaciones:
  shell <usuario> <shell>                         Cambia la shell
  comentario <usuario> <texto>                    Cambia el comentario (nombre completo)
  grupo-primario <usuario> <grupo>                Cambia el grupo primario
  bloquear <usuario>                              Bloquea la cuenta
  desbloquear <usuario>                           Desbloquea la cuenta

Configuración de acceso:
  resetear <usuario>                              Nueva contraseña temporal (cambio obligatorio)
  expiracion <usuario> [dias]                     Días de vigencia de la contraseña

Consultas:
  listar                                          Lista los usuarios normales
  info <usuario>                                  Muestra los datos de un usuario

  ayuda                                           Muestra esta ayuda

Ejemplos:
  sudo $0 crear mperez "Maria Perez" dm_dev,dm_backup
  sudo $0 bloquear mperez
  sudo $0 eliminar mperez
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
        crear)          crear_usuario "$@" ;;
        csv)            crear_usuarios_csv "$@" ;;
        eliminar)       eliminar_usuario "$@" ;;
        shell)          modificar_shell "$@" ;;
        comentario)     modificar_comentario "$@" ;;
        grupo-primario) modificar_grupo_primario "$@" ;;
        bloquear)       bloquear_usuario "$@" ;;
        desbloquear)    desbloquear_usuario "$@" ;;
        resetear)       resetear_password "$@" ;;
        expiracion)     configurar_expiracion "$@" ;;
        listar)         listar_usuarios ;;
        info)           info_usuario "$@" ;;
        *)              error "Comando desconocido: '$comando'"; mostrar_ayuda; return 1 ;;
    esac
}

# Ejecuta main solo si el archivo se corre directamente (no si se hace "source")
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
