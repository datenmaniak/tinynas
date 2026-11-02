#!/usr/bin/env bash
#
# backup-tinynas-dinamico.sh
# Respaldo iterativo por carpetas del home del USER hacia /mnt/tinynas (NFS)
# leyendo los directorios desde un archivo externo y depurando eliminados (incluyendo ocultos).
#
#   sudo DRY_RUN=1 ./backup-etc-iteractivo-tinynas.sh    # solo simula
#   sudo DELETE_AFTER=1 ./backup-etc-iteractivo-tinynas.sh  # con --delete-after
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

HOST="prueba"       # nombre del repositorio en el NFS server, reservado para este PC/Usuario.
#                   # la ruta de montaje esta determinada por el NFS, con acceso a otros repositorios solo para lectura.

HOME_USER="/home/${USER}"
SCRIPT_DIR="/home/${USER}/admin/tinynas"
EXCLUDE_FILE="${SCRIPT_DIR}/exclude-tinynas.txt"
DIRECTORIOS_FILE="${SCRIPT_DIR}/directorios_home.txt"
LOCK_FILE="${SCRIPT_DIR}/backup-tinynas-dinamico.lock"

NFS_ROOT="/var/mnt/tinynas/${HOST}"
CENTINELA="${NFS_ROOT}/.tinynas-id"
DESTINO_BASE="${NFS_ROOT}/automated-backup"

DESTINO_HOME="${DESTINO_BASE}/home/${HOST}"
#TODO: se ajusta $HOST para coincidir con la ruta NFS del usuario local.  -  DESTINO_HOME="${DESTINO_BASE}/home/${USER}"

DESTINO_ETC="${DESTINO_BASE}/etc"


LOG_FILE="/home/${USER}/backup.log"

# Umbral mínimo de espacio libre en el destino (en MiB)
ESPACIO_MIN_MB=512

# Variables de control (override por entorno)
DRY_RUN="${DRY_RUN:-0}"           # 1 = simular, 0 = copiar de verdad
DELETE_AFTER="${DELETE_AFTER:-0}" # 1 = añadir --delete-after a rsync


# Opciones rsync optimizadas para NFS
RSYNC_OPTS=(
  -aHAX
  --numeric-ids
  --exclude-from="${EXCLUDE_FILE}"
  --info=progress2
  --filter='-x security.selinux'
  --filter='-x system.nfs4_acl'
  --partial
  --inplace
  -z
)

[[ "${DRY_RUN}" == "1" ]] && RSYNC_OPTS+=( -n )
[[ "${DELETE_AFTER}" == "1" ]] && RSYNC_OPTS+=( --delete-after )


# ---------------------------------------------------------------------------
# Utilidades de log
# ---------------------------------------------------------------------------
log() {
  local nivel="$1"
  shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Lock para evitar solapamiento
# ---------------------------------------------------------------------------
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log_warn "Ejecución previa en curso (lock ${LOCK_FILE} tomado). Abortando."
  exit 0
fi

log_info "=== Inicio de respaldo dinámico por carpetas ==="

# ---------------------------------------------------------------------------
# Verificaciones previas
# ---------------------------------------------------------------------------
if ! command -v rsync >/dev/null 2>&1; then
  log_error "rsync no está instalado. Abortando."
  exit 1
fi

if [[ ! -r "${EXCLUDE_FILE}" ]]; then
  log_error "No se puede leer ${EXCLUDE_FILE}. Abortando."
  exit 1
fi

if [[ ! -r "${DIRECTORIOS_FILE}" ]]; then
  log_error "No se puede leer ${DIRECTORIOS_FILE}. Abortando."
  exit 1
fi

# Forzar montaje autofs con timeout
if ! timeout 20 ls "${NFS_ROOT}" >/dev/null 2>&1; then
  log_error "No se pudo acceder a ${NFS_ROOT} (autofs no montó o NFS caído). Abortando."
  exit 1
fi
log_info "autofs/NFS accesible en ${NFS_ROOT}."

# Centinela: solo advertencia
if [[ ! -e "${CENTINELA}" ]]; then
  log_warn "Centinela ${CENTINELA} no encontrado. Se continúa."
else
  log_info "Centinela encontrado: $(cat "${CENTINELA}" 2>/dev/null | head -n1)"
fi

# Espacio libre en destino
ESPACIO_LIBRE_MB=$(df -Pm "${NFS_ROOT}" | awk 'NR==2 {print $4}')
if [[ -z "${ESPACIO_LIBRE_MB}" || "${ESPACIO_LIBRE_MB}" -lt "${ESPACIO_MIN_MB}" ]]; then
  log_error "Espacio libre insuficiente en ${NFS_ROOT} (${ESPACIO_LIBRE_MB:-?} MiB < ${ESPACIO_MIN_MB} MiB). Abortando."
  exit 1
fi
log_info "Espacio libre en destino: ${ESPACIO_LIBRE_MB} MiB."

# Crear estructura base destino si no existe
  if [ ! -d "${DESTINO_HOME}" ]; then
    echo "[User repo no found ] ${DESTINO_HOME}" 
    mkdir -p "${DESTINO_HOME}" >> "${LOG_FILE}" 2>&1  || {
    log_error "No se pudo crear la estructura en ${DESTINO_BASE}. Abortando."
    exit 1
  }
  else
    log_info "[Repo already created] ${DESTINO_HOME}" 
  fi
  

# TODO: pendiente de revisar bloque ETC
#  if [ ! -d "${DESTINO_ETC}" ]; then 
#  echo "[Not found] ${DESTINO_ETC}" 
#  mkdir -p "${DESTINO_ETC}" 2>/dev/null ||  {
#    log_error "No se pudo crear la estructura en ${DESTINO_BASE}. Abortando."
#    exit 1
#  }
#else 
#    log_info "[ETC Repo Ready] ${DESTINO_HOME}" 
#  fi


# ---------------------------------------------------------------------------
# Depuración previa: Eliminar del destino carpetas que ya no están en directorios_home.txt
# ---------------------------------------------------------------------------
if [[ -d "${DESTINO_HOME}" ]]; then
  # Recopilar carpetas válidas del archivo de configuración
  declare -A CARPETAS_VALIDAS
  while IFS= read -r linea || [[ -n "${linea}" ]]; do
    [[ -z "${linea}" || "${linea}" =~ ^[[:space:]]*# ]] && continue
    limpia=$(echo "${linea}" | xargs)
    [[ -n "${limpia}" ]] && CARPETAS_VALIDAS["${limpia}"]=1
  done <"${DIRECTORIOS_FILE}"

  # Habilitar dotglob para que el asterisco (*) también reconozca directorios ocultos (ej. .local, .config)
  shopt -s dotglob
  for destino_item in "${DESTINO_HOME}"/*; do
    if [[ -d "${destino_item}" ]]; then
      nombre_dir=$(basename "${destino_item}")
      # Omitir comodines especiales por seguridad
      [[ "${nombre_dir}" == "." || "${nombre_dir}" == ".." ]] && continue

      if [[ -z "${CARPETAS_VALIDAS["${nombre_dir}"]:-}" ]]; then
        log_warn "La carpeta '${nombre_dir}' ya no está en ${DIRECTORIOS_FILE}. Eliminando del destino..."
        rm -rf "${destino_item}" >> "${LOG_FILE}" 2>&1
        log_info "Carpeta '${nombre_dir}' eliminada del NAS."
      fi
    fi
  done
  shopt -u dotglob # Desactivar dotglob para restaurar comportamiento estándar
fi

# ---------------------------------------------------------------------------
# Respaldo iterativo leyendo directorios_home.txt
# ---------------------------------------------------------------------------
RC_HOME=0

while IFS= read -r carpeta || [[ -n "${carpeta}" ]]; do
  # Omitir líneas vacías o comentarios que comiencen con '#'
  [[ -z "${carpeta}" || "${carpeta}" =~ ^[[:space:]]*# ]] && continue

  # Eliminar espacios o retornos de carro sobrantes
  carpeta=$(echo "${carpeta}" | xargs)

  
  # incluye soporte para archivos sueltos | 16.10.26, 13:59
  ORIGEN_FULL="${HOME_USER}/${carpeta}"
  DESTINO_FULL="${DESTINO_HOME}/${carpeta}"

  if [[ -d "${ORIGEN_FULL}" ]]; then

    echo "[Folders not found ] ${ORIGEN_FULL}" 

    # --- Caso 1: es un directorio -> copia contenido recursivo ---
    log_info "Iniciando rsync del directorio: ${carpeta}"
    mkdir -p "${DESTINO_FULL}/" >> "${LOG_FILE}" 2>&1

    rsync "${RSYNC_OPTS[@]}" \
      "${ORIGEN_FULL}/" \
      "${DESTINO_FULL}/" >> "${LOG_FILE}" 2>&1

    RC_SUB=$?

  elif [[ -f "${ORIGEN_FULL}" ]]; then
    # --- Caso 2: es un archivo suelto -> copia el archivo en su ruta padre ---
    log_info "Iniciando rsync del archivo: ${carpeta}"
    PADRE_DESTINO="$(dirname "${DESTINO_FULL}")"
    mkdir -p "${PADRE_DESTINO}" >> "${LOG_FILE}" 2>&1

    sudo rsync "${RSYNC_OPTS[@]}" \
      "${ORIGEN_FULL}" \
      "${PADRE_DESTINO}/" >> "${LOG_FILE}" 2>&1

    RC_SUB=$?

  else
    log_warn "La ruta origen ${ORIGEN_FULL} no existe. Omitiendo."
    continue
  fi

  case "${RC_SUB}" in
  0)  log_info "Entrada [${carpeta}]: rsync OK (código 0)." ;;
  24) log_warn "Entrada [${carpeta}]: rsync completó con código 24 (archivos desaparecieron)." ;;
  *)
    log_error "Entrada [${carpeta}]: rsync falló con código ${RC_SUB}."
    RC_HOME=1
    ;;
  esac

done <"${DIRECTORIOS_FILE}"

# ---------------------------------------------------------------------------
# Resumen final
TAM_HOME=$(du -sh "${DESTINO_HOME}" 2>/dev/null | awk '{print $1}')
log_info "Tamaño total destino home: ${TAM_HOME:-?}"

RC_FINAL=0
[[ "${RC_HOME}" -ne 0 ]] && RC_FINAL=1

log_info "=== Fin de respaldo dinámico (código agregado: ${RC_FINAL}) ==="
log_info "--- terminado $(date)   -----"
exit "${RC_FINAL}"
