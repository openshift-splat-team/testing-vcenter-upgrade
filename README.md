# testing-vcenter-upgrade

Validates that an OpenShift cluster on vSphere survives a vCenter in-place upgrade or replacement without requiring a cluster redeploy.

## Purpose

This tool provides before/after verification for vCenter upgrades. The script captures cluster state before the upgrade, then validates that the cluster remained healthy and functional after vCenter returns.

## Prerequisites

- `oc` and `python3` installed
- `KUBECONFIG` pointing at the target cluster
- Cluster admin permissions

## Usage

```bash
export KUBECONFIG=/path/to/cluster/kubeconfig

# 1) Capture baseline state before touching vCenter
./scripts/vcenter-upgrade-e2e.sh baseline

# 2) Perform the vCenter upgrade/replacement
#    (This step is manual - the script does not automate it)

# 3) Validate cluster health after vCenter is back
./scripts/vcenter-upgrade-e2e.sh verify

# 4) Clean up test resources
./scripts/vcenter-upgrade-e2e.sh cleanup
```

## What it verifies

- **Machines**: No force-delete or re-provisioning occurred (same names, stable UIDs, all Running)
- **Nodes**: All nodes returned to Ready state
- **Storage continuity**: Existing PV I/O remained uninterrupted (canary workload log advanced without restart)
- **Storage provisioning**: New PVCs can be provisioned and attached post-upgrade
- **Cluster operators**: All ClusterOperators remain Available, not Progressing, not Degraded
- **Configuration impact**: Flags any vCenter thumbprint changes or MachineConfig divergence

## Important notes

- Run `baseline` and `verify` with the same `$STATE` file (default: `/tmp/vc-upgrade-e2e.state`)
- Override canary namespace with `NS=<name>` if needed
- Script exits non-zero if any check fails
