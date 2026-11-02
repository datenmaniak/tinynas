#!/usr/bin/env bash
#
# backup-tinynas-etc.sh
# Respaldo selectivo de archivos y directorios de /etc hacia /mnt/tinynas (NFS)
# leyendo los objetivos desde un archivo de configuración externo y depurando eliminados.
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------



HOST="ryzen"  # nombre del equipo: ryzen o victus

SCRIPT_DIR="/home/${USER}/admin/tinynas"
DIRECTORIOS_ETC_FILE="${SCRIPT_DIR}/directorios_etc.txt"
EXCLUDE_ETC_FILE="${SCRIPT_DIR}/exclude-etc.txt"
LOCK_FILE="${SCRIPT_DIR}/backup-tinynas-etc.lock"

NFS_ROOT="/var/mnt/tinynas/${HOST}"

CENTINELA="${NFS_ROOT}/.tinynas-id"
DESTINO_BASE="${NFS_ROOT}/automated-backup"
DESTINO_ETC="${DESTINO_BASE}/etc"

LOG_FILE="/home/${USER}/backup.log"

# Umbral mínimo de espacio libre en el destino (en MiB)
ESPACIO_MIN_MB=512

# Opciones rsync optimizadas para archivos de sistema
RSYNC_OPTS=(
  -aHAX
  --numeric-ids
  --info=progress2
  -z
  --filter='-x security.selinux'
  --filter='-x system.nfs4_acl'
  --ignore-times 
)

  # --delete-after
  # --partial
  # --inplace


# Añadir archivo de exclusión opcional si existe
if [[ -r "${EXCLUDE_ETC_FILE}" ]]; then
  RSYNC_OPTS+=( --exclude-from="${EXCLUDE_ETC_FILE}" )
fi

# ---------------------------------------------------------------------------
# Utilidades de log
# ---------------------------------------------------------------------------
log() {
  local nivel="$1"
  shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [ETC] [${nivel}] $*" >>"${LOG_FILE}"
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

log_info "=== Inicio de respaldo de /etc ==="

# ---------------------------------------------------------------------------
# Verificaciones previas
# ---------------------------------------------------------------------------
#if [[ $EUID -ne 0 ]]; then
#  log_error "Este script requiere privilegios de superusuario (sudo) para leer /etc correctamente."
#  exit 1
#fi

if ! command -v rsync >/dev/null 2>&1; then
  log_error "rsync no está instalado. Abortando."
  exit 1
fi

if [[ ! -r "${EXCLUDE_ETC_FILE}" ]]; then
  log_error "No se puede leer ${EXCLUDE_FILE}. Abortando."
  exit 1
fi

if [[ ! -r "${DIRECTORIOS_ETC_FILE}" ]]; then
  log_error "No se puede leer ${DIRECTORIOS_ETC_FILE}. Abortando."
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
fi

# Espacio libre en destino
ESPACIO_LIBRE_MB=$(df -Pm "${NFS_ROOT}" | awk 'NR==2 {print $4}')
if [[ -z "${ESPACIO_LIBRE_MB}" || "${ESPACIO_LIBRE_MB}" -lt "${ESPACIO_MIN_MB}" ]]; then
  log_error "Espacio libre insuficiente en ${NFS_ROOT} (${ESPACIO_LIBRE_MB:-?} MiB < ${ESPACIO_MIN_MB} MiB). Abortando."
  exit 1
fi

# Crear estructura base destino si no existe
mkdir -p "${DESTINO_ETC}" 2>/dev/null || {
 log_error "No se pudo crear la estructura en ${DESTINO_ETC}. Abortando."
 exit 1
}

# ---------------------------------------------------------------------------
# Depuración previa: Eliminar del destino elementos que ya no están en directorios_etc.txt
# ---------------------------------------------------------------------------
if [[ -d "${DESTINO_ETC}" ]]; then
  # Recopilar rutas válidas del archivo de configuración
  declare -A RUTAS_VALIDAS
  while IFS= read -r linea || [[ -n "${linea}" ]]; do
    [[ -z "${linea}" || "${linea}" =~ ^[[:space:]]*# ]] && continue
    limpia=$(echo "${linea}" | xargs)
    [[ -n "${limpia}" ]] && RUTAS_VALIDAS["${limpia}"]=1
  done < "${DIRECTORIOS_ETC_FILE}"

  # Escanear lo que existe actualmente en el destino de /etc en el NAS
  shopt -s dotglob
  for destino_item in "${DESTINO_ETC}"/*; do
    if [[ -e "${destino_item}" ]]; then
      nombre_item=$(basename "${destino_item}")
      [[ "${nombre_item}" == "." || "${nombre_item}" == ".." ]] && continue
      
      # Si el elemento en el destino no está en el archivo de configuración, eliminarlo
      if [[ -z "${RUTAS_VALIDAS["${nombre_item}"]:-}" ]]; then
        log_warn "El elemento '/etc/${nombre_item}' ya no está en ${DIRECTORIOS_ETC_FILE}. Eliminando del destino..."
       # sudo rm -rf "${destino_item}"
        log_info "Elemento '${nombre_item}' eliminado del NAS."
      fi
    fi
  done
  shopt -u dotglob
fi

# ---------------------------------------------------------------------------
# Respaldo iterativo leyendo directorios_etc.txt
# ---------------------------------------------------------------------------
RC_ETC=0

while IFS= read -r ruta || [[ -n "${ruta}" ]]; do
  [[ -z "${ruta}" || "${ruta}" =~ ^[[:space:]]*# ]] && continue
  ruta=$(echo "${ruta}" | xargs)

  ORIGEN_ITEM="/etc/${ruta}"
  DESTINO_ITEM="${DESTINO_ETC}/${ruta}"

  if [[ -e "${ORIGEN_ITEM}" ]]; then
    log_info "Iniciando rsync de: /etc/${ruta}"
    
    if [[ -d "${ORIGEN_ITEM}" ]]; then
     sudo mkdir -p "${DESTINO_ITEM}"
    else
     sudo mkdir -p "$(dirname "${DESTINO_ITEM}")"
    fi
    
    sudo rsync "${RSYNC_OPTS[@]}" \
      "${ORIGEN_ITEM}" \
      "${DESTINO_ITEM}" >>"${LOG_FILE}" 2>&1
    
    RC_SUB=$?
    case "${RC_SUB}" in
      0) log_info "Elemento [/etc/${ruta}]: rsync OK." ;;
      24) log_warn "Elemento [/etc/${ruta}]: completó con código 24 (archivos desaparecieron)." ;;
      *) 
        log_error "Elemento [/etc/${ruta}]: rsync falló con código ${RC_SUB}."
        RC_ETC=1
        ;;
    esac
  else
    log_warn "El origen /etc/${ruta} no existe en el sistema. Omitiendo."
  fi
done < "${DIRECTORIOS_ETC_FILE}"

# ---------------------------------------------------------------------------
# Resumen final
# ---------------------------------------------------------------------------
TAM_ETC=$(du -sh "${DESTINO_ETC}" 2>/dev/null | awk '{print $1}')
log_info "=== Fin de respaldo de /etc (Tamaño total: ${TAM_ETC:-?}) ==="

RC_FINAL=0
[[ "${RC_ETC}" -ne 0 ]] && RC_FINAL=1
exit "${RC_FINAL}"
