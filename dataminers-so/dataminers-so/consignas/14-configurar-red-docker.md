# Configurar red Docker

**Etiqueta:** Administración de SO

## Consigna

Crear y configurar la red interna de Docker para permitir la comunicación segura entre los diferentes contenedores.

## Archivos que la resuelven

- docker/docker-compose.yml (sección `networks`)

## Cómo probarla

```bash
docker network ls | grep dm_
docker network inspect dm_back
```
