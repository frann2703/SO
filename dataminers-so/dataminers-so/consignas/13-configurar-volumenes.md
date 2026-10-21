# Configurar volúmenes

**Etiqueta:** Administración de SO

## Consigna

Configurar volúmenes Docker para garantizar la persistencia de los datos necesarios, especialmente los de la base de datos.

## Archivos que la resuelven

- docker/docker-compose.yml (sección `volumes`)

## Cómo probarla

```bash
docker volume ls | grep dm_
docker compose down && docker compose up -d   # los datos persisten
```
