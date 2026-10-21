# Docker Compose

**Etiqueta:** Administración de SO

## Consigna

Configurar Docker Compose para gestionar los diferentes servicios, redes, variables y volúmenes del proyecto.

## Archivos que la resuelven

- `docker/docker-compose.yml`
- `docker/.env.example`

## Cómo probarla

```bash
cd docker && cp .env.example .env
docker compose config
docker compose up -d --build
```
