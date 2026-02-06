#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Capacity Reservation incremental creation with logging
###############################################################################

# ----------------------------- Default Configuration -----------------------
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
DRY_RUN="${DRY_RUN:-false}"

# ---------------------------- Argument Parsing -----------------------------
show_help() {
  cat << EOF
Usage: $0 [OPTIONS]

Incremental Azure Capacity Reservation creation script.

OPTIONS:
  --subscription-id ID      Azure subscription ID
  --resource-group NAME     Resource group name
  --location LOCATION       Azure region (e.g., eastus, westeurope)
  --zone ZONE              Availability zone (default: 1)
  --rcg-name NAME          Capacity reservation group name
  --cr-name NAME           Capacity reservation name
  --vm-sku, --sku SKU      VM SKU (default: Standard_D2s_v5)
  --capacity NUMBER        Target capacity (default: 2)
  --sleep-seconds SECONDS  Sleep between retries (default: 3600)
  --log-file FILE          Log file path (default: log.txt)
  --out-file FILE          Output file path (default: capacity.txt)
  --dry-run                Validate only, don't create resources
  --help, -h               Show this help message

EXAMPLES:
  $0 --subscription-id "12345678-1234-1234-1234-123456789012" \\
     --resource-group "rg-test" --location "eastus" --capacity 3

  $0 --dry-run --rcg-name "test-rcg" --capacity 1
EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --subscription-id)
        SUBSCRIPTION_ID="$2"
        shift 2
        ;;
      --resource-group)
        RESOURCE_GROUP="$2"
        shift 2
        ;;
      --location)
        LOCATION="$2"
        shift 2
        ;;
      --zone)
        ZONE="$2"
        shift 2
        ;;
      --rcg-name)
        CRG_NAME="$2"
        shift 2
        ;;
      --cr-name)
        CR_NAME="$2"
        shift 2
        ;;
      --vm-sku|--sku)
        VM_SKU="$2"
        shift 2
        ;;
      --capacity)
        TARGET_CAPACITY="$2"
        shift 2
        ;;
      --sleep-seconds)
        SLEEP_SECONDS="$2"
        shift 2
        ;;
      --log-file)
        LOG_FILE="$2"
        shift 2
        ;;
      --out-file)
        OUT_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        echo "ERROR: Unknown option: $1" >&2
        echo "Use --help for usage information." >&2
        exit 1
        ;;
    esac
  done
}

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

validate_parameters() {
  log "Validating parameters..."
  
  if [[ -z "$SUBSCRIPTION_ID" ]]; then
    log "ERROR: SUBSCRIPTION_ID is required"
    exit 1
  fi
  
  if [[ -z "$RESOURCE_GROUP" ]]; then
    log "ERROR: RESOURCE_GROUP is required"
    exit 1
  fi
  
  if [[ -z "$LOCATION" ]]; then
    log "ERROR: LOCATION is required"
    exit 1
  fi
  
  if [[ ! "$TARGET_CAPACITY" =~ ^[0-9]+$ ]] || [[ "$TARGET_CAPACITY" -lt 1 ]]; then
    log "ERROR: TARGET_CAPACITY must be a positive integer"
    exit 1
  fi
  
  if [[ "$DRY_RUN" == "true" ]]; then
    log "🔍 DRY RUN MODE: Validating parameters only"
    log "✅ All parameters are valid"
    log "Configuration:"
    log "  - Subscription ID: $SUBSCRIPTION_ID"
    log "  - Resource Group: $RESOURCE_GROUP"
    log "  - Location: $LOCATION"
    log "  - Zone: $ZONE"
    log "  - CRG Name: $CRG_NAME"
    log "  - CR Name: $CR_NAME"
    log "  - VM SKU: $VM_SKU"
    log "  - Target Capacity: $TARGET_CAPACITY"
    exit 0
  fi
  
  log "✅ Parameter validation successful"
}

# ------------------------------ Main logic ----------------------------------
main() {
  # Parse command line arguments first
  parse_arguments "$@"
  
  log "----- START capacity reservation incremental creation -----"
  acquire_lock
  
  # Validate all parameters
  validate_parameters

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

    local create_err
    if create_err=$(az capacity reservation create \
      -g "$RESOURCE_GROUP" \
      --capacity-reservation-group "$CRG_NAME" \
      -n "$CR_NAME" \
      --sku "$VM_SKU" \
      --capacity "$current_capacity" \
      --zone "$ZONE" \
      -o none 2>&1)
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
    else
      log "ERROR: az capacity reservation create failed:"
      log "$create_err"
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

      local update_err
      if update_err=$(az capacity reservation update \
        -g "$RESOURCE_GROUP" \
        --capacity-reservation-group "$CRG_NAME" \
        -n "$CR_NAME" \
        --capacity "$current_capacity" \
        -o none 2>&1)
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
      else
        log "ERROR: az capacity reservation update failed:"
        log "$update_err"
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