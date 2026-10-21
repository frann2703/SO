# Contenedor de aplicación

**Etiqueta:** Administración de SO

## Consigna

Crear y configurar el contenedor encargado de ejecutar la aplicación y garantizar su correcto funcionamiento.

## Archivos que la resuelven

- `docker/Dockerfile`
- docker/docker-compose.yml (servicio `app`)

## Cómo probarla

```bash
docker compose ps
docker compose logs -f app
```
