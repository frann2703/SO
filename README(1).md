# DataMiners · Administración de SO

Scripts de administración y configuración Docker del proyecto **DataMiners (SGRSI 2026)**:
sistema de gestión para la coordinación de informática del ITI.

Cada tarea de Administración de SO tiene su **consigna** (el texto de la tarjeta de Trello) en
`consignas/` y el código que la resuelve en `scripts/` o `docker/`. El encabezado de cada archivo
también incluye su consigna.

## Tareas

| Nº | Tarea | Consigna | Código |
|---|---|---|---|
| 1 | Script de usuarios | [01-script-de-usuarios.md](consignas/01-script-de-usuarios.md) | `scripts/usuarios.sh` |
| 2 | Script de grupos | [02-script-de-grupos.md](consignas/02-script-de-grupos.md) | `scripts/grupos.sh` |
| 3 | Script de backups | [03-script-de-backups.md](consignas/03-script-de-backups.md) | `scripts/backups.sh` |
| 4 | Script de redes | [04-script-de-redes.md](consignas/04-script-de-redes.md) | `scripts/redes.sh` |
| 5 | Script de base de datos | [05-script-de-base-de-datos.md](consignas/05-script-de-base-de-datos.md) | `scripts/basedatos.sh`, `docker/initdb/01_schema.sql` |
| 6 | Script de firewall | [06-script-de-firewall.md](consignas/06-script-de-firewall.md) | `scripts/firewall.sh` |
| 7 | Script de logs | [07-script-de-logs.md](consignas/07-script-de-logs.md) | `scripts/logs.sh` |
| 8 | Integrar scripts de forma modular | [08-integrar-scripts-de-forma-modular.md](consignas/08-integrar-scripts-de-forma-modular.md) | `scripts/administrar.sh` |
| 9 | Dockerfile | [09-dockerfile.md](consignas/09-dockerfile.md) | `docker/Dockerfile` |
| 10 | Docker Compose | [10-docker-compose.md](consignas/10-docker-compose.md) | `docker/docker-compose.yml`, `docker/.env.example` |
| 11 | Contenedor de aplicación | [11-contenedor-de-aplicacion.md](consignas/11-contenedor-de-aplicacion.md) | `docker/Dockerfile`, docker/docker-compose.yml (servicio `app`) |
| 12 | Contenedor MySQL | [12-contenedor-mysql.md](consignas/12-contenedor-mysql.md) | docker/docker-compose.yml (servicio `db`), `docker/initdb/01_schema.sql`, `docker/.env.example` |
| 13 | Configurar volúmenes | [13-configurar-volumenes.md](consignas/13-configurar-volumenes.md) | docker/docker-compose.yml (sección `volumes`) |
| 14 | Configurar red Docker | [14-configurar-red-docker.md](consignas/14-configurar-red-docker.md) | docker/docker-compose.yml (sección `networks`) |
| 15 | Servidor de respaldo | [15-servidor-de-respaldo.md](consignas/15-servidor-de-respaldo.md) | `scripts/servidor_respaldo.sh` |
| 16 | Probar restauración de backup | [16-probar-restauracion-de-backup.md](consignas/16-probar-restauracion-de-backup.md) | `scripts/probar_restauracion.sh` |

## Estructura

```
scripts/     scripts bash modulares (administrar.sh los une)
docker/      Dockerfile, docker-compose.yml, .env.example y esquema SQL inicial
consignas/   una consigna por tarea
AGENTS.md    contexto del proyecto para asistentes de código (OpenCode)
```

## Uso rápido

```bash
chmod +x scripts/*.sh
sudo ./scripts/administrar.sh modulos     # lista los módulos
sudo ./scripts/administrar.sh menu        # menú interactivo
sudo ./scripts/administrar.sh <modulo> ayuda
```

Docker: `cd docker && cp .env.example .env` (completar contraseñas) y `docker compose up -d --build`.

## Supuestos a revisar

- SO: Ubuntu Server (se usan `ufw` y `netplan`).
- Backend: Node.js (`server.js`, puerto 3000). Si es otra tecnología, cambiar `docker/Dockerfile`.
- `docker/initdb/01_schema.sql` es una propuesta base: reemplazar por el modelo real.
