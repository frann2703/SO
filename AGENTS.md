# AGENTS.md - Contexto del proyecto

## Qué es este repositorio
Código de la parte de **Administración de SO** del proyecto **DataMiners (SGRSI 2026)**: scripts bash
para administrar un servidor Linux y la configuración Docker (app Node.js + MySQL) de un sistema de
gestión para la coordinación de informática del ITI.

## Cómo leerlo
1. Cada tarea tiene su consigna en `consignas/NN-nombre.md` (texto original de la tarjeta de Trello,
   archivos que la resuelven y comandos de prueba). El índice está en `README.md`.
2. Antes de modificar o explicar un archivo, leé la consigna de su tarea: define el objetivo.
3. El encabezado de cada script/archivo Docker repite la consigna en la línea `Consigna :`.

## Convenciones de los scripts (`scripts/*.sh`)
- Bash con `set -u`. Idioma de comentarios, ayuda y mensajes: **español**.
- Estructura fija: configuración por variables de entorno -> utilidades (`info`, `aviso`, `error`,
  `verificar_root`) -> funciones por operación -> `mostrar_ayuda` -> `main` con `case` de comandos.
- Cada script funciona solo y también puede cargarse con `source` (el `main` solo corre si se ejecuta
  directamente). `administrar.sh` los integra como módulos.
- Requieren root (`sudo`). Registran en `/var/log/dataminers/<modulo>.log`.
- Validan toda entrada (nombres, puertos, IPs) antes de ejecutar comandos del sistema.
- Operaciones peligrosas tienen modo simulacro (`DRY_RUN=1` en `firewall.sh` y `redes.sh`) o backup previo.
- Las credenciales nunca van en el código: se leen del archivo `.env` (ver `docker/.env.example`).
  Nunca commitear `.env`.

## Docker (`docker/`)
- `Dockerfile`: Node 20 alpine, multi-etapa, usuario no root, healthcheck.
- `docker-compose.yml`: servicios `app` y `db` (MySQL 8.0), redes `dm_front` y `dm_back` (interna),
  volúmenes `dm_db_data` y `dm_app_logs`. El puerto 3306 NO se publica.
- `initdb/01_schema.sql`: esquema inicial de ejemplo (se ejecuta en el primer arranque de MySQL).

## Verificación
```bash
for f in scripts/*.sh; do bash -n "$f"; done      # sintaxis
shellcheck -S warning scripts/*.sh                # estilo (opcional)
docker compose -f docker/docker-compose.yml config   # validar el compose
```

## Supuestos pendientes de confirmar
Ubuntu Server como SO, backend Node.js en el puerto 3000, y el esquema SQL es solo una base.
