# Script de redes

**Etiqueta:** Administración de SO

## Consigna

Automatizar las configuraciones y comprobaciones necesarias para garantizar el correcto funcionamiento de la red.

## Archivos que la resuelven

- `scripts/redes.sh`

## Cómo probarla

```bash
sudo ./scripts/redes.sh ayuda
sudo ./scripts/redes.sh comprobar
sudo DRY_RUN=1 ./scripts/redes.sh configurar-ip enp0s3 192.168.1.10/24 192.168.1.1
```
