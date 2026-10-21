# =============================================================================
# Dockerfile - Imagen del contenedor de la aplicación
# Proyecto : DataMiners - SGRSI 2026
# Tarea    : Dockerfile (Administración de SO)
# Consigna : Dockerfile: Crear y configurar el Dockerfile necesario para
#            construir la imagen del contenedor de la aplicación.
# Consigna : Contenedor de aplicación: Crear y configurar el contenedor
#            encargado de ejecutar la aplicación y garantizar su correcto
#            funcionamiento.
#
# SUPUESTO: la aplicación es Node.js (package.json + server.js en la raíz del
# repositorio) y escucha en el puerto 3000. Si el backend usa otra tecnología,
# solo hay que cambiar la imagen base, la instalación de dependencias y el CMD.
#
# Construir desde la RAÍZ del repositorio:
#   docker build -f docker/Dockerfile -t dataminers/app:latest .
# =============================================================================

# ---------- Etapa 1: dependencias (se cachea si package*.json no cambia) ------
FROM node:20-alpine AS dependencias
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ---------- Etapa 2: imagen final (liviana y sin herramientas de compilación) --
FROM node:20-alpine

LABEL org.opencontainers.image.title="DataMiners App" \
      org.opencontainers.image.description="Sistema de gestión de la coordinación de informática - ITI" \
      org.opencontainers.image.authors="DataMiners"

ENV NODE_ENV=production \
    PORT=3000 \
    HEALTH_PATH=/health \
    TZ=America/Montevideo

# tini: manejo correcto de señales y procesos zombie dentro del contenedor
RUN apk add --no-cache tini tzdata

WORKDIR /app

COPY --from=dependencias /app/node_modules ./node_modules
COPY --chown=node:node . .

# Carpeta de logs escribible por el usuario no-root
RUN mkdir -p /app/logs && chown node:node /app/logs

# Seguridad: no ejecutar como root
USER node

EXPOSE 3000

# El contenedor se marca "healthy" cuando la app responde
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -q --spider "http://127.0.0.1:${PORT}${HEALTH_PATH}" || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
