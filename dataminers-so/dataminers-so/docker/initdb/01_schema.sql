-- =============================================================================
-- 01_schema.sql - Esquema inicial (PROPUESTA BASE)
-- Proyecto: DataMiners - SGRSI 2026
--
-- Se ejecuta automáticamente la PRIMERA vez que arranca el contenedor MySQL
-- (volumen db_data vacío) y también lo usa: sudo ./basedatos.sh importar
--
-- IMPORTANTE: es una base genérica según el problema del proyecto (soporte,
-- inventario y actores Solicitante / Técnico / Administrador). Reemplazar o
-- ajustar según el DER/modelo real del equipo.
-- =============================================================================

CREATE TABLE IF NOT EXISTS usuarios (
    id             INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    nombre         VARCHAR(80)  NOT NULL,
    apellido       VARCHAR(80)  NOT NULL,
    email          VARCHAR(150) NOT NULL UNIQUE,
    password_hash  VARCHAR(255) NOT NULL,
    rol            ENUM('solicitante','tecnico','administrador') NOT NULL DEFAULT 'solicitante',
    activo         TINYINT(1)   NOT NULL DEFAULT 1,
    creado_en      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS equipos (
    id                 INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    codigo_inventario  VARCHAR(40)  NOT NULL UNIQUE,
    tipo               VARCHAR(60)  NOT NULL,
    marca              VARCHAR(60),
    modelo             VARCHAR(60),
    ubicacion          VARCHAR(120),
    estado             ENUM('operativo','en_reparacion','baja') NOT NULL DEFAULT 'operativo',
    creado_en          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS solicitudes (
    id              INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    solicitante_id  INT UNSIGNED NOT NULL,
    tecnico_id      INT UNSIGNED NULL,
    equipo_id       INT UNSIGNED NULL,
    titulo          VARCHAR(150) NOT NULL,
    descripcion     TEXT,
    prioridad       ENUM('baja','media','alta') NOT NULL DEFAULT 'media',
    estado          ENUM('pendiente','en_proceso','resuelta','cerrada') NOT NULL DEFAULT 'pendiente',
    creado_en       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    actualizado_en  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_sol_solicitante FOREIGN KEY (solicitante_id) REFERENCES usuarios(id),
    CONSTRAINT fk_sol_tecnico     FOREIGN KEY (tecnico_id)     REFERENCES usuarios(id),
    CONSTRAINT fk_sol_equipo      FOREIGN KEY (equipo_id)      REFERENCES equipos(id),
    INDEX idx_sol_estado (estado)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
