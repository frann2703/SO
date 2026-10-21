# Contenedor MySQL

**Etiqueta:** Administración de SO

## Consigna

Configurar el contenedor de MySQL, incluyendo credenciales, base de datos, persistencia y conexión con la aplicación.

## Archivos que la resuelven

- docker/docker-compose.yml (servicio `db`)
- `docker/initdb/01_schema.sql`
- `docker/.env.example`

## Cómo probarla

```bash
docker compose ps
docker exec -it dm_db mysql -uroot -p
```
