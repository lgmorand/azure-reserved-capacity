# Azure Capacity Reservation — FAQ

> A practical, technical FAQ about **On-Demand Capacity Reservation** on Azure:
> what it is, how to attach/detach resources, how to share a group across subscriptions,
> and which permissions are required. Commands use the Azure CLI (`az`).

---

## 1. Concepts

### 1.1 What is a Capacity Reservation?

An **On-Demand Capacity Reservation** reserves compute capacity (a specific **VM size**,
in a specific **region**, and optionally an **availability zone**) so that it is guaranteed
to be available whenever you need it. Once created, the capacity is reserved for you
**even if no VM is running on it** — and you are billed for it from that moment on.

It solves the "I got an *allocation failure* when I tried to start my VM" problem for
business-critical workloads.

### 1.2 What is a Capacity Reservation Group (CRG / "RCG")?

A **Capacity Reservation Group (CRG)** is a logical container that holds one or more
**Capacity Reservations**. You always:

1. create a **group** (the CRG), then
2. create one or more **reservations** inside it (one per VM size / zone), then
3. **associate** your VMs / VM Scale Sets with the **group**.

> In this repository the group is sometimes abbreviated **RCG** ("Reserved Capacity Group").
> In Azure's official terminology it is the **Capacity Reservation Group (CRG)**.

```
Capacity Reservation Group (CRG)
├── Capacity Reservation  (Standard_D2s_v5, zone 1, capacity = 3)
├── Capacity Reservation  (Standard_D2s_v5, zone 2, capacity = 2)
└── Capacity Reservation  (Standard_E4s_v5, zone 1, capacity = 1)
```

### 1.3 Is "Reserved Capacity" the same as a "Reserved Instance"?

**No — and this is the most common confusion.**

| | On-Demand Capacity Reservation (this repo) | Reserved Instance / Savings Plan |
|---|---|---|
| Goal | **Guarantee capacity is available** | **Get a discount** (1 or 3-year commitment) |
| Billing | Pay-as-you-go rate for the reserved capacity | Discounted, prepaid/committed |
| Commitment | None — delete anytime | 1 or 3 years |
| Allocation guarantee | ✅ Yes | ❌ No (it's only a billing construct) |

You **can combine them**: a Reserved Instance discount automatically applies to capacity
reserved via an On-Demand Capacity Reservation for the matching VM size/region.

---

## 2. Creating capacity

### 2.1 Create a Capacity Reservation Group

```bash
az capacity reservation group create \
  --resource-group rg-capacity \
  --name crg-prod-frc \
  --location francecentral \
  --zones 1 2 3
```

### 2.2 Create a Capacity Reservation inside the group

```bash
az capacity reservation create \
  --resource-group rg-capacity \
  --capacity-reservation-group crg-prod-frc \
  --name cr-d2sv5-az1 \
  --sku Standard_D2s_v5 \
  --capacity 3 \
  --zone 1
```

- `--sku` — the exact VM size you want to reserve.
- `--capacity` — how many instances of that size to reserve.
- `--zone` — must be one of the zones declared on the group (omit for regional).

> 💡 **Tip:** capacity may not be granted instantly for large sizes/quantities.
> The [`script.sh`](script.sh) in this repo creates the reservation with `capacity=1`
> and **increments it one unit at a time**, retrying on failure — a robust pattern when
> capacity is scarce.

### 2.3 Change (scale) the reserved capacity

```bash
az capacity reservation update \
  --resource-group rg-capacity \
  --capacity-reservation-group crg-prod-frc \
  --name cr-d2sv5-az1 \
  --capacity 5
```

---

## 3. Attaching (associating) resources

### 3.1 Attach a **new** VM at creation time

Pass the **group ID** (not the reservation) to `az vm create`:

```bash
CRG_ID=$(az capacity reservation group show \
  -g rg-capacity -n crg-prod-frc --query id -o tsv)

az vm create \
  --resource-group rg-workloads \
  --name vm-app-1 \
  --location francecentral \
  --size Standard_D2s_v5 \
  --image Ubuntu2204 \
  --zone 1 \
  --capacity-reservation-group "$CRG_ID" \
  --generate-ssh-keys
```

The VM **size and zone must match** a reservation that exists in the group, otherwise the
VM simply won't consume the reservation (or creation fails).

### 3.2 Attach an **existing** VM

An existing VM must be **deallocated (stopped)** before it can be associated:

```bash
az vm deallocate -g rg-workloads -n vm-app-1

az vm update -g rg-workloads -n vm-app-1 \
  --set capacityReservation.capacityReservationGroup.id="$CRG_ID"

az vm start -g rg-workloads -n vm-app-1
```

### 3.3 Attach a VM Scale Set (VMSS)

```bash
az vmss update -g rg-workloads -n vmss-app \
  --set virtualMachineProfile.capacityReservation.capacityReservationGroup.id="$CRG_ID"
# then update the instances / reimage as needed
```

### 3.4 What about over-allocation?

You can attach **more VMs than you reserved**. The reservation guarantees capacity **up to**
the reserved amount; VMs beyond that are served as normal on-demand capacity (no guarantee).
The `deploy.yaml` workflow in this repo demonstrates this by reserving `2` and starting `3` VMs.

---

## 4. Detaching (disassociating) resources

### 4.1 Detach an existing VM

The VM must again be **deallocated** first:

```bash
az vm deallocate -g rg-workloads -n vm-app-1

az vm update -g rg-workloads -n vm-app-1 \
  --remove capacityReservation

az vm start -g rg-workloads -n vm-app-1
```

### 4.2 Delete a reservation / group (order matters)

A group can only be deleted once it is **empty**:

1. **Disassociate all VMs/VMSS** from the group (section 4.1).
2. Delete each capacity reservation:
   ```bash
   az capacity reservation delete \
     -g rg-capacity --capacity-reservation-group crg-prod-frc \
     -n cr-d2sv5-az1 --yes
   ```
3. Delete the group:
   ```bash
   az capacity reservation group delete \
     -g rg-capacity -n crg-prod-frc --yes
   ```

> If you get *"cannot delete, resources still associated"*, some VM is still pointing at the
> group — find and disassociate it first.

---

## 5. Sharing a group across subscriptions

A Capacity Reservation Group can be **shared with other subscriptions in the same Microsoft
Entra (Azure AD) tenant**, so VMs living in subscription B can consume capacity reserved in
subscription A.

### 5.1 Enable sharing

Pass the **subscription resource IDs** to share with via `--sharing-profile`
(space-separated list of `/subscriptions/<id>`):

```bash
az capacity reservation group update \
  --resource-group rg-capacity \
  --name crg-prod-frc \
  --sharing-profile \
    /subscriptions/11111111-1111-1111-1111-111111111111 \
    /subscriptions/22222222-2222-2222-2222-222222222222
```

### 5.2 Stop sharing

Pass an empty value to clear the sharing list:

```bash
az capacity reservation group update \
  --resource-group rg-capacity \
  --name crg-prod-frc \
  --sharing-profile ""
```

### 5.3 Rules & limits for cross-subscription sharing

- All subscriptions **must be in the same Entra tenant**.
- The shared subscriptions can **consume** the capacity but **cannot modify** the group.
- Consuming VMs reference the **group ID** in the owning subscription.
- Deleting/disassociating rules from sections 3–4 still apply per resource.

---

## 6. Permissions (RBAC) — what do I need?

### 6.1 To create / manage a Capacity Reservation Group

You need write access on the reservation resources in the subscription/resource group that
**owns** the group. **Contributor** (or **Owner**) covers this. The key control-plane actions are:

```
Microsoft.Compute/capacityReservationGroups/write
Microsoft.Compute/capacityReservationGroups/capacityReservations/write
```

### 6.2 To **link a resource (VM/VMSS) to a CRG** — the important one

Associating a resource with a group requires this specific action **on the group**:

```
Microsoft.Compute/capacityReservationGroups/deploy/action
```

This action is **included** in:

- **Owner**
- **Contributor**
- **Virtual Machine Contributor**

It is **not** included in **Reader** or **Capacity Reservation Reader**. So a principal that
can create VMs (e.g. *Virtual Machine Contributor*) but has only *Reader* on the group's
resource group **will fail** to associate the VM. Grant it the `.../deploy/action` permission
on the CRG — the cleanest way is a role assignment scoped to the CRG (or its resource group).

### 6.3 Least-privilege example: allow a team to consume a shared CRG

Create a custom role that only permits deploying into the group, then assign it scoped to the
CRG:

```jsonc
// crg-consumer-role.json
{
  "Name": "Capacity Reservation Consumer",
  "IsCustom": true,
  "Description": "Can associate VMs with a capacity reservation group, nothing else.",
  "Actions": [
    "Microsoft.Compute/capacityReservationGroups/read",
    "Microsoft.Compute/capacityReservationGroups/deploy/action"
  ],
  "AssignableScopes": [
    "/subscriptions/<sub-id>/resourceGroups/rg-capacity"
  ]
}
```

```bash
az role definition create --role-definition crg-consumer-role.json

CRG_ID=$(az capacity reservation group show -g rg-capacity -n crg-prod-frc --query id -o tsv)

az role assignment create \
  --assignee "<user-or-sp-object-id>" \
  --role "Capacity Reservation Consumer" \
  --scope "$CRG_ID"
```

### 6.4 Cross-subscription sharing & permissions

- To **enable sharing** (section 5) you need write permission on the group in the **owning**
  subscription (**Contributor**/**Owner**).
- To **consume** the shared group from another subscription, the consuming principal needs
  `Microsoft.Compute/capacityReservationGroups/deploy/action` **on the shared group** (grant a
  role assignment scoped to the CRG for that principal/team) **plus** the usual VM-create
  permissions in its own subscription.

---

## 7. Billing & quotas

- You are billed for **reserved capacity as soon as it is created**, whether or not a VM runs
  on it — at the normal pay-as-you-go rate for that VM size.
- Reserved capacity **counts against your regional vCPU quota**. Reserving 10 × `D2s_v5`
  consumes that quota just like running 10 VMs would.
- A matching **Reserved Instance / Savings Plan** discount automatically applies to the
  reserved capacity (see section 1.3).

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| VM create/associate fails with an authorization error | Missing `Microsoft.Compute/capacityReservationGroups/deploy/action` on the CRG (section 6.2). |
| VM starts but doesn't consume the reservation | VM **size** or **zone** doesn't match any reservation in the group. |
| Can't associate an existing VM | VM must be **deallocated** first (section 3.2). |
| Can't delete the group | A VM/VMSS is still associated, or reservations still exist (section 4.2). |
| Capacity reservation stuck / not `Succeeded` | Capacity temporarily unavailable — retry, reduce quantity, or try another zone. See `script.sh` retry logic. |
| Cross-subscription VM can't use capacity | Subscriptions not in same tenant, or missing `deploy/action` on the shared CRG (sections 5 & 6.4). |

---

## 9. References

- [Azure — On-demand Capacity Reservation overview](https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-overview)
- [Associate / disassociate a VM (portal & CLI)](https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-associate-vm)
- [Share a capacity reservation group across subscriptions](https://learn.microsoft.com/azure/virtual-machines/capacity-reservation-overview)
- [`az capacity reservation group`](https://learn.microsoft.com/cli/azure/capacity/reservation/group)
- [Azure RBAC — Compute resource provider operations](https://learn.microsoft.com/azure/role-based-access-control/resource-provider-operations#microsoftcompute)

> ⚠️ This repository is a **demo** for educational purposes only — no support, no warranty.
> Always validate commands in a non-production subscription first.
