#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Capacity Reservation incremental creation with logging
###############################################################################

# ----------------------------- Configuration --------------------------------
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-3126b4c2-cba4-40e9-9d3d-a3b031cdea56}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-capacity}"
LOCATION="${LOCATION:-francecentral}"
ZONE="${ZONE:-1}"
CRG_NAME="${CRG_NAME:-crg-prod-frc-az1}"
CR_NAME="${CR_NAME:-cr-standard-d2sv5-az1}"
VM_SKU="${VM_SKU:-Standard_D2s_v5}"
TARGET_CAPACITY="${TARGET_CAPACITY:-2}"
SLEEP_SECONDS="${SLEEP_SECONDS:-3600}"
LOG_FILE="${LOG_FILE:-log.txt}"
OUT_FILE="${OUT_FILE:-capacity.txt}"
LOCK_FILE="${LOCK_FILE:-.capacity_reservation.lock}"

# ------------------------------- Helpers ------------------------------------
log() {
  echo "[$(date +"%Y-%m-%dT%H:%M:%S%z")] $*" | tee -a "$LOG_FILE"
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "ERROR: Another instance is running. Exiting."
    exit 1
  fi
}

# ------------------------------ Main logic ----------------------------------
main() {
  log "----- START capacity reservation incremental creation -----"
  acquire_lock

  # Check Azure login
  if ! az account show &>/dev/null; then
    log "ERROR: Not logged in to Azure. Run 'az login'."
    exit 1
  fi

  # Set subscription
  log "Setting subscription: $SUBSCRIPTION_ID"
  az account set --subscription "$SUBSCRIPTION_ID"

  # Create resource group (idempotent)
  log "Ensuring resource group: $RESOURCE_GROUP"
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none 2>/dev/null || true

  # Create capacity reservation group (idempotent)
  log "Ensuring capacity reservation group: $CRG_NAME"
  az capacity reservation group create \
    -g "$RESOURCE_GROUP" \
    -n "$CRG_NAME" \
    -l "$LOCATION" \
    --zones "$ZONE" \
    -o none 2>/dev/null || true

  # Step 1: Create initial capacity reservation with capacity=1
  local current_capacity=1
  local attempt=0
  
  log "Creating initial capacity reservation with capacity=$current_capacity"
  
  while true; do
    attempt=$((attempt+1))
    log "Attempt #$attempt: creating capacity reservation '$CR_NAME' (SKU=$VM_SKU, capacity=$current_capacity)"

    if az capacity reservation create \
      -g "$RESOURCE_GROUP" \
      --capacity-reservation-group "$CRG_NAME" \
      -n "$CR_NAME" \
      --sku "$VM_SKU" \
      --capacity "$current_capacity" \
      --zone "$ZONE" \
      -o none 2>/dev/null
    then
      # Check provisioning state
      local state
      state="$(az capacity reservation show \
        -g "$RESOURCE_GROUP" \
        --capacity-reservation-group "$CRG_NAME" \
        -n "$CR_NAME" \
        --query "provisioningState" -o tsv)"

      log "Provisioning state: $state"

      if [[ "$state" == "Succeeded" ]]; then
        log "SUCCESS: Initial capacity reservation created with capacity=$current_capacity"
        break
      fi
    fi

    log "Retrying in ${SLEEP_SECONDS}s..."
    sleep "$SLEEP_SECONDS"
  done

  # Step 2: Incrementally increase capacity until target is reached
  while [[ $current_capacity -lt $TARGET_CAPACITY ]]; do
    current_capacity=$((current_capacity+1))
    attempt=0
    
    log "Increasing capacity to $current_capacity (target: $TARGET_CAPACITY)"
    
    while true; do
      attempt=$((attempt+1))
      log "Attempt #$attempt: updating capacity to $current_capacity"

      if az capacity reservation update \
        -g "$RESOURCE_GROUP" \
        --capacity-reservation-group "$CRG_NAME" \
        -n "$CR_NAME" \
        --capacity "$current_capacity" \
        -o none 2>/dev/null
      then
        # Check provisioning state
        local state
        state="$(az capacity reservation show \
          -g "$RESOURCE_GROUP" \
          --capacity-reservation-group "$CRG_NAME" \
          -n "$CR_NAME" \
          --query "provisioningState" -o tsv)"

        log "Provisioning state: $state"

        if [[ "$state" == "Succeeded" ]]; then
          log "SUCCESS: Capacity updated to $current_capacity"
          break
        fi
      fi

      log "Retrying in ${SLEEP_SECONDS}s..."
      sleep "$SLEEP_SECONDS"
    done
  done

  log "SUCCESS: Target capacity of $TARGET_CAPACITY reached"

  # Export details
  az capacity reservation show \
    -g "$RESOURCE_GROUP" \
    --capacity-reservation-group "$CRG_NAME" \
    -n "$CR_NAME" > "$OUT_FILE"

  log "Details written to $OUT_FILE. Exiting."
  exit 0
}

main "$@"