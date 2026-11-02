#!/usr/bin/bash 
#
# backup-iteractivo-dirsfiles-tinynas.sh 
#
# Respaldo iterativo por carpetas y archivos del home del USER hacia /mnt/tinynas (NFS)
# leyendo las rutas desde un archivo externo y depurando eliminados (incluyendo ocultos).
#
# Uso:
#   ./backup-iteractivo-dirsfiles-tinynas.sh               # Ejecución normal
#   DRY_RUN=1 ./backup-iteractivo-dirsfiles-tinynas.sh     # Modo simulación
#   DELETE_AFTER=1 ./backup-iteractivo-dirsfiles-tinynas.sh # Elimina en el destino archivos borrados en origen

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

NFSPATH="ryzen"     # Nombre de la ruta en el servidor NFS asignada a la estación/usuario.

HOME_USER="/home/${USER}"
SCRIPT_DIR="${SCRIPTS}/tinynas"
MAIN_EXCLUDE="${SCRIPT_DIR}/main-exclude.txt"
INCLUDESFILE="${SCRIPT_DIR}/home-dirs.txt"
LOCK_FILE="${SCRIPT_DIR}/backup-tinynas-dinamico.lock"

# Listas de exclusiones adicionales para afinar el filtrado
EXCLUDE_DOTCONFIG="${SCRIPT_DIR}/dot_config_exclude.txt"
EXCLUDE_DOTLOCAL="${SCRIPT_DIR}/dot_local_exclude.txt"

NFS_ROOT="/var/mnt/tinynas/${NFSPATH}"
CENTINELA="${NFS_ROOT}/.tinynas-id"
DESTINO_BASE="${NFS_ROOT}/automated-backup"
DESTINO_HOME="${DESTINO_BASE}/home/${USER}"

LOG_FILE="/tmp/tinynas.log"

# Umbral mínimo de espacio libre en el destino (en MiB)
ESPACIO_MIN_MB=512

# Variables de control (override por entorno)
DRY_RUN="${DRY_RUN:-0}"           # 1 = simular, 0 = copiar de verdad
DELETE_AFTER="${DELETE_AFTER:-0}" # 1 = añadir --delete-after a rsync

# Opciones rsync optimizadas para NFS (Se omitió --ignore-times para permitir incrementales eficientes)
RSYNC_OPTS=(
  -aHAX
  --numeric-ids
  --exclude-from="${MAIN_EXCLUDE}"
  --info=progress2
  --filter='-x security.selinux'
  --filter='-x system.nfs4_acl'
  -z
)

# Añadir exclusiones adicionales de forma dinámica si los archivos existen
[[ -r "${EXCLUDE_DOTCONFIG}" ]] && RSYNC_OPTS+=( --exclude-from="${EXCLUDE_DOTCONFIG}" )
[[ -r "${EXCLUDE_DOTLOCAL}" ]] && RSYNC_OPTS+=( --exclude-from="${EXCLUDE_DOTLOCAL}" )

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
  echo "[${ts}] [${nivel}] $*" >>"${LOG_FILE}"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Lock para evitar ejecuciones simultáneas
# ---------------------------------------------------------------------------
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log_warn "Ejecución previa en curso (lock ${LOCK_FILE} tomado). Abortando."
  exit 0
fi

clear
log_info "---------- Inicio de respaldo dinámico por carpetas -----------------"

# ---------------------------------------------------------------------------
# Verificaciones previas
# ---------------------------------------------------------------------------
if ! command -v rsync >/dev/null 2>&1; then
  log_error "rsync no está instalado. Abortando."
  exit 1
fi

if [[ ! -r "${MAIN_EXCLUDE}" ]]; then
  log_error "No se puede leer ${MAIN_EXCLUDE}. Abortando."
  exit 1
fi

if [[ ! -r "${INCLUDESFILE}" ]]; then
  log_error "No se puede leer ${INCLUDESFILE}. Abortando."
  exit 1
fi

# Forzar montaje autofs / verificación de conectividad con timeout
if ! timeout 20 ls "${NFS_ROOT}" >/dev/null 2>&1; then
  log_error "No se pudo acceder a ${NFS_ROOT} (autofs no montó o NFS caído). Abortando."
  exit 1
fi
log_info "autofs/NFS accesible en ${NFS_ROOT}."

# Verificación de Centinela
if [[ ! -e "${CENTINELA}" ]]; then
  log_warn "Centinela ${CENTINELA} no encontrado. Se continúa."
else
  log_info "Centinela encontrado: $(head -n1 "${CENTINELA}" 2>/dev/null)"
fi

# Verificación de espacio libre en el destino
ESPACIO_LIBRE_MB=$(df -Pm "${NFS_ROOT}" | awk 'NR==2 {print $4}')
if [[ -z "${ESPACIO_LIBRE_MB}" || "${ESPACIO_LIBRE_MB}" -lt "${ESPACIO_MIN_MB}" ]]; then
  log_error "Espacio libre insuficiente en ${NFS_ROOT} (${ESPACIO_LIBRE_MB:-?} MiB < ${ESPACIO_MIN_MB} MiB). Abortando."
  exit 1
fi
log_info "Espacio libre en destino: ${ESPACIO_LIBRE_MB} MiB."

# Crear directorio base de destino en el NAS si no existe
if [[ ! -d "${DESTINO_HOME}" ]]; then
  log_info "[User repo not found/Created] ${DESTINO_HOME}" 
  mkdir -p "${DESTINO_HOME}" >> "${LOG_FILE}" 2>&1 || {
    log_error "No se pudo crear la estructura en ${DESTINO_HOME}. Abortando."
    exit 1
  }
else
  log_info "[Repo already exists] ${DESTINO_HOME}" 
fi

# ---------------------------------------------------------------------------
# Depuración previa: Eliminar del NAS elementos que ya no están en la lista
# ---------------------------------------------------------------------------
if [[ -d "${DESTINO_HOME}" ]]; then

  declare -A CARPETAS_VALIDAS
  while IFS= read -r linea || [[ -n "${linea}" ]]; do
    [[ -z "${linea}" || "${linea}" =~ ^[[:space:]]*# ]] && continue
    limpia="$(echo "${linea}" | xargs)"
    [[ -n "${limpia}" ]] && CARPETAS_VALIDAS["${limpia}"]=1
  done < "${INCLUDESFILE}"

  # Activar dotglob para incluir carpetas ocultas que inicien con punto
  old_dotglob=$(shopt -p dotglob)
  shopt -s dotglob

  for destino_item in "${DESTINO_HOME}"/*; do
    [[ -d "${destino_item}" ]] || continue
    nombre_dir=$(basename "${destino_item}")

    [[ "${nombre_dir}" == "." || "${nombre_dir}" == ".." ]] && continue

    if [[ -z "${CARPETAS_VALIDAS[$nombre_dir]:-}" ]]; then
      log_warn "La carpeta '${nombre_dir}' ya no está en la lista (${INCLUDESFILE})."

      if [[ "${DRY_RUN}" == "0" ]]; then
        total_items=$(find "${destino_item}" -mindepth 1 2>/dev/null | wc -l)
        log_info "Eliminando '${nombre_dir}' del NAS (${total_items} elementos)..."

        rm -rf -- "${destino_item}" >> "${LOG_FILE}" 2>&1
        rm_status=$?

        if [[ ${rm_status} -ne 0 ]]; then
          log_error "Fallo al eliminar '${destino_item}' (código ${rm_status})"
        else
          log_info "Carpeta '${nombre_dir}' eliminada del NAS con éxito."
        fi
      else
        log_info "[DRY-RUN] Se eliminaría '${nombre_dir}' del NAS"
      fi
    fi
  done

  eval "$old_dotglob"
fi

# ---------------------------------------------------------------------------
# Respaldo iterativo leyendo el archivo de inclusiones
# ---------------------------------------------------------------------------
RC_HOME=0
echo "Backup in progress. No cierre esta ventana..."

while IFS= read -r carpeta || [[ -n "${carpeta}" ]]; do
  # Omitir líneas vacías o comentarios
  [[ -z "${carpeta}" || "${carpeta}" =~ ^[[:space:]]*# ]] && continue

  carpeta="$(echo "${carpeta}" | xargs)"
  [[ -z "${carpeta}" ]] && continue

  ORIGEN_FULL="${HOME_USER}/${carpeta}"
  DESTINO_FULL="${DESTINO_HOME}/${carpeta}"

  if [[ -d "${ORIGEN_FULL}" ]]; then

    # Comprobación real de existencia previa en el destino para un logging claro
    if [[ ! -d "${DESTINO_FULL}" ]]; then
      log_warn "[No encontrado en el destino - Se creará] ${DESTINO_FULL}"
    else
      log_info "[Existe en el destino] Sincronizando directorio: ${carpeta}"
    fi

    # --- Caso 1: Es un directorio -> copia contenido recursivo ---
    mkdir -p "${DESTINO_FULL}/" >> "${LOG_FILE}" 2>&1 

    rsync "${RSYNC_OPTS[@]}" \
      "${ORIGEN_FULL}/" \
      "${DESTINO_FULL}/" >> "${LOG_FILE}" 2>&1

    RC_SUB=$?

  elif [[ -f "${ORIGEN_FULL}" ]]; then

    # --- Caso 2: Es un archivo suelto -> copia el archivo en su ruta padre ---
    log_info "Iniciando rsync del archivo: ${carpeta}"
    PADRE_DESTINO="$(dirname "${DESTINO_FULL}")"
    mkdir -p "${PADRE_DESTINO}" >> "${LOG_FILE}" 2>&1 

    rsync "${RSYNC_OPTS[@]}" \
      "${ORIGEN_FULL}" \
      "${PADRE_DESTINO}/" >> "${LOG_FILE}" 2>&1

    RC_SUB=$?

  else
    log_warn "La ruta origen ${ORIGEN_FULL} no existe en el sistema. Omitiendo."
    continue
  fi

  # Evaluación del resultado de rsync por elemento
  case "${RC_SUB}" in
    0)  log_info "Entrada [${carpeta}]: rsync OK (código 0)." ;;
    24) log_warn "Entrada [${carpeta}]: rsync completó con código 24 (archivos desaparecieron durante la copia)." ;;
    *)
      log_error "Entrada [${carpeta}]: rsync falló con código ${RC_SUB}."
      RC_HOME=1
      ;;
  esac

done <"${INCLUDESFILE}"

# ---------------------------------------------------------------------------
# Resumen final y cierre
# ---------------------------------------------------------------------------
TAM_HOME=$(du -sh "${DESTINO_HOME}" 2>/dev/null | awk '{print $1}')
log_info "Tamaño total destino home en NAS: ${TAM_HOME:-?}"

RC_FINAL=0
[[ "${RC_HOME}" -ne 0 ]] && RC_FINAL=1

log_info "----------- Fin de respaldo (código final: ${RC_FINAL}) ---- $(date) ----"
exit "${RC_FINAL}"
