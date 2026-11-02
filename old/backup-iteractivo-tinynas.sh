#!/usr/bin/env bash
#
# backup-tinynas-dinamico.sh
# Respaldo iterativo por carpetas del home del USER hacia /mnt/tinynas (NFS)
# leyendo los directorios desde un archivo externo y depurando eliminados (incluyendo ocultos).
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

HOST="ryzen"  # nombre del equipo: ryzen o victus

HOME_USER="/home/${USER}"
SCRIPT_DIR="/home/${USER}/admin/tinynas"
EXCLUDE_FILE="${SCRIPT_DIR}/exclude-tinynas.txt"
DIRECTORIOS_FILE="${SCRIPT_DIR}/directorios_home.txt"
LOCK_FILE="${SCRIPT_DIR}/backup-tinynas-dinamico.lock"

NFS_ROOT="/var/mnt/tinynas/${HOST}"
CENTINELA="${NFS_ROOT}/.tinynas-id"
DESTINO_BASE="${NFS_ROOT}/automated-backup"
DESTINO_HOME="${DESTINO_BASE}/home/${USER}"
DESTINO_ETC="${DESTINO_BASE}/etc"

LOG_FILE="/home/${USER}/backup.log"

# Umbral mínimo de espacio libre en el destino (en MiB)
ESPACIO_MIN_MB=512

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

# No se incluye en los parametros mientras evaluacion
# --delete-after


# ---------------------------------------------------------------------------
# Utilidades de log
# ---------------------------------------------------------------------------
log() {
  local nivel="$1"
  shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [${nivel}] $*" >>"${LOG_FILE}"
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
mkdir -p "${DESTINO_HOME}" "${DESTINO_ETC}" 2>/dev/null || {
  log_error "No se pudo crear la estructura en ${DESTINO_BASE}. Abortando."
  exit 1
}

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
        #sudo rm -rfv "${destino_item}"
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

  ORIGEN_CARPETA="${HOME_USER}/${carpeta}/"
  DESTINO_CARPETA="${DESTINO_HOME}/${carpeta}/"

  if [[ -d "${HOME_USER}/${carpeta}" ]]; then
    log_info "Iniciando rsync de la carpeta: ${carpeta}"
    sudo mkdir -p "${DESTINO_CARPETA}"

    sudo rsync "${RSYNC_OPTS[@]}" \
      "${ORIGEN_CARPETA}" \
      "${DESTINO_CARPETA}" >> "${LOG_FILE}" 2>&1

    RC_SUB=$?
    case "${RC_SUB}" in
    0) log_info "Carpeta [${carpeta}]: rsync OK (código 0)." ;;
    24) log_warn "Carpeta [${carpeta}]: rsync completó con código 24 (archivos desaparecieron)." ;;
    *)
      log_error "Carpeta [${carpeta}]: rsync falló con código ${RC_SUB}."
      RC_HOME=1
      ;;
    esac
  else
    log_warn "La carpeta origen ${HOME_USER}/${carpeta} no existe. Omitiendo."
  fi
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
