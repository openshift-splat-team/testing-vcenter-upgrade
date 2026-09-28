set -uo pipefail

NS="${NS:-vc-upgrade-e2e}"
CANARY_IMAGE="${CANARY_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"
STATE="${STATE:-/tmp/vc-upgrade-e2e.state}"
SC="${SC:-}"

PASS=0; FAIL=0
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
ok(){   PASS=$((PASS+1)); green  "  PASS: $*"; }
bad(){  FAIL=$((FAIL+1)); red    "  FAIL: $*"; }
warn(){ yellow "  WARN: $*"; }
hdr(){ echo; echo "== $* =="; }

need(){ command -v "$1" >/dev/null || { red "missing dependency: $1"; exit 2; }; }
need oc; need python3

default_sc(){
  [ -n "$SC" ] && { echo "$SC"; return; }
  oc get sc -o json | python3 -c 'import sys,json;print(next((s["metadata"]["name"] for s in json.load(sys.stdin)["items"] if s["metadata"].get("annotations",{}).get("storageclass.kubernetes.io/is-default-class")=="true"),""))'
}

# machine identity signature: name|uid|phase  (uid change == re-provision)
machine_sig(){ oc get machines -n openshift-machine-api -o json | python3 -c 'import sys,json
for m in sorted(json.load(sys.stdin)["items"],key=lambda x:x["metadata"]["name"]):
    print("%s|%s|%s"%(m["metadata"]["name"],m["metadata"]["uid"],m.get("status",{}).get("phase","")))'; }

nodes_ready(){ oc get nodes -o json | python3 -c 'import sys,json
for n in json.load(sys.stdin)["items"]:
    r=next((c["status"] for c in n["status"]["conditions"] if c["type"]=="Ready"),"?")
    print("%s|%s"%(n["metadata"]["name"],r))'; }

co_health(){ oc get co -o json | python3 -c 'import sys,json
for c in json.load(sys.stdin)["items"]:
    d={x["type"]:x["status"] for x in c["status"]["conditions"]}
    print("%s|A=%s|P=%s|D=%s"%(c["metadata"]["name"],d.get("Available"),d.get("Progressing"),d.get("Degraded")))'; }

vc_thumbprint(){ oc get cm cloud-provider-config -n openshift-config -o jsonpath='{.data.config}' 2>/dev/null | grep -iE 'thumbprint' | tr -d ' ' | grep -v "thumbprint:''" | head -1; }

mcp_rendered(){ oc get mcp -o json | python3 -c 'import sys,json
for p in json.load(sys.stdin)["items"]:
    print("%s|desired=%s|current=%s"%(p["metadata"]["name"],p["spec"].get("configuration",{}).get("name"),p["status"].get("configuration",{}).get("name")))'; }

writer_lines(){ oc exec -n "$NS" writer -- sh -c 'wc -l /data/log.txt 2>/dev/null | cut -d" " -f1' 2>/dev/null | tr -d '[:space:]'; }
writer_restarts(){ oc get pod writer -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null; }

save(){ echo "$1=$2" >> "$STATE"; }
load(){ grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-; }

# ---------------------------------------------------------------- baseline ----
baseline(){
  local sc; sc="$(default_sc)"; [ -z "$sc" ] && { red "no storageclass"; exit 2; }
  : > "$STATE"
  hdr "BASELINE (pre-upgrade)  ns=$NS  sc=$sc"

  machine_sig  > "${STATE}.machines"
  nodes_ready  > "${STATE}.nodes"
  co_health    > "${STATE}.co"
  mcp_rendered > "${STATE}.mcp"
  save thumbprint "$(vc_thumbprint)"
  echo "  machines: $(wc -l < ${STATE}.machines)  nodes: $(wc -l < ${STATE}.nodes)"
  echo "  vCenter thumbprint: $(load thumbprint)"

  hdr "Create canary PV + writer (continuous I/O across the window)"
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata: { name: $NS }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: canary, namespace: $NS }
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }
  storageClassName: $sc
---
apiVersion: v1
kind: Pod
metadata: { name: writer, namespace: $NS }
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: writer
    image: $CANARY_IMAGE
    command: ["/bin/sh","-c"]
    args: ["i=0; while true; do i=\$((i+1)); echo \"\$(date -u +%Y-%m-%dT%H:%M:%SZ) line=\$i\" >> /data/log.txt; sync; sleep 5; done"]
    securityContext: { allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: { drop: ["ALL"] } }
    volumeMounts: [{ name: vol, mountPath: /data }]
  volumes: [{ name: vol, persistentVolumeClaim: { claimName: canary } }]
EOF
  oc wait -n "$NS" --for=condition=Ready pod/writer --timeout=180s || { bad "canary writer did not start (image pullable on its node?)"; exit 1; }
  sleep 8
  local n; n="$(writer_lines)"
  save writer_lines_baseline "$n"
  save writer_node "$(oc get pod writer -n $NS -o jsonpath='{.spec.nodeName}')"
  ok "canary writer running, baseline lines=$n on node $(load writer_node)"
  echo
  green "BASELINE SAVED to $STATE — now perform the vCenter upgrade/replacement, then run: $0 verify"
}

# ------------------------------------------------------------------ verify ----
verify(){
  [ -f "$STATE" ] || { red "no baseline state ($STATE). run '$0 baseline' first"; exit 2; }
  hdr "VERIFY (post-upgrade)  ns=$NS"

  hdr "SPLAT-2932  Machine API: no force-delete / no re-provision"
  machine_sig > "${STATE}.machines.now"
  local base_names now_names base_line
  base_names="$(cut -d'|' -f1 ${STATE}.machines | sort)"
  now_names="$(cut -d'|' -f1 ${STATE}.machines.now | sort)"
  if [ "$base_names" = "$now_names" ]; then ok "same machine set (none force-deleted/added)"
  else bad "machine set changed:"; diff <(echo "$base_names") <(echo "$now_names") | sed 's/^/      /'; fi
  # uid change on a surviving name == silent re-provision
  local reprov=0
  while IFS='|' read -r nm uid ph; do
    local nowline; nowline="$(grep "^$nm|" ${STATE}.machines.now)"
    [ -z "$nowline" ] && continue
    local nowuid; nowuid="$(echo "$nowline" | cut -d'|' -f2)"
    [ "$uid" != "$nowuid" ] && { bad "machine $nm re-provisioned (uid changed)"; reprov=1; }
  done < "${STATE}.machines"
  [ "$reprov" = 0 ] && ok "no machine re-provisioned (all UIDs stable)"
  # all Running
  if grep -qv '|Running$' <(cut -d'|' -f1,3 ${STATE}.machines.now | sed 's/|/ /' | awk '{print $1"|"$2}'); then
    oc get machines -n openshift-machine-api -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers | grep -v ' Running$' | sed 's/^/      /'
    bad "some machines not Running"
  else ok "all machines Running"; fi

  hdr "Nodes Ready (auto-recovered after vCenter resumed)"
  if nodes_ready | grep -qv '|True$'; then nodes_ready | grep -v '|True$' | sed 's/^/      /'; bad "some nodes NotReady"
  else ok "all nodes Ready"; fi

  hdr "SPLAT-2926  ClusterOperators healthy"
  if co_health | grep -qvE '\|A=True\|P=False\|D=False$'; then co_health | grep -vE '\|A=True\|P=False\|D=False$' | sed 's/^/      /'; bad "unhealthy ClusterOperators"
  else ok "all ClusterOperators Available, not Progressing, not Degraded"; fi

  hdr "SPLAT-2933  Existing PV I/O continuity"
  local r n0 n1
  r="$(writer_restarts)"; n0="$(load writer_lines_baseline)"; n1="$(writer_lines)"
  [ "$r" = "0" ] && ok "canary writer never restarted (restarts=0)" || bad "canary writer restarted $r time(s) — mount was disrupted"
  if [ -n "$n1" ] && [ "${n1:-0}" -gt "${n0:-0}" ]; then ok "canary I/O continued across window (lines $n0 -> $n1)"
  else bad "canary I/O did NOT advance (lines $n0 -> ${n1:-none})"; fi

  hdr "SPLAT-2933  New provisioning + attach recovered"
  local sc; sc="$(default_sc)"
  cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: postcheck, namespace: $NS }
spec: { accessModes: ["ReadWriteOnce"], resources: { requests: { storage: 1Gi } }, storageClassName: $sc }
---
apiVersion: v1
kind: Pod
metadata: { name: postcheck, namespace: $NS }
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: c
    image: $CANARY_IMAGE
    command: ["/bin/sh","-c","echo ok > /data/x; sync; sleep 100000"]
    securityContext: { allowPrivilegeEscalation: false, runAsNonRoot: true, capabilities: { drop: ["ALL"] } }
    volumeMounts: [{ name: v, mountPath: /data }]
  volumes: [{ name: v, persistentVolumeClaim: { claimName: postcheck } }]
EOF
  if oc wait -n "$NS" --for=condition=Ready pod/postcheck --timeout=180s >/dev/null 2>&1; then
    ok "new PVC provisioned + attached + mounted post-upgrade"
  else
    warn "postcheck pod not Ready in 180s — inspect (may be image pull vs storage):"
    oc get pvc postcheck -n "$NS" --no-headers | sed 's/^/      /'
    oc describe pod postcheck -n "$NS" | sed -n '/Events/,$p' | tail -6 | sed 's/^/      /'
    # distinguish storage failure from image pull
    if oc describe pod postcheck -n "$NS" | grep -qiE 'FailedAttachVolume|ProvisioningFailed|x509'; then bad "new volume provisioning/attach FAILED"; else warn "not a storage failure (likely image pull) — verify manually"; fi
  fi

  hdr "SPLAT-2934  cloud-provider-config / MCO impact"
  local tb0 tb1; tb0="$(load thumbprint)"; tb1="$(vc_thumbprint)"
  if [ "$tb0" = "$tb1" ]; then ok "vCenter thumbprint unchanged ($tb1) — in-place upgrade preserved identity"
  else warn "vCenter thumbprint CHANGED ($tb0 -> $tb1) — replacement identity; cloud-provider-config had to be updated"; fi
  # rendered MachineConfig divergence == pending rolling reboot (Bug B)
  if diff -q "${STATE}.mcp" <(mcp_rendered) >/dev/null; then ok "MCP rendered configs unchanged — no forced rolling reboot"
  else warn "MCP rendered config changed since baseline (potential rolling reboot / Bug B):"; diff "${STATE}.mcp" <(mcp_rendered) | sed 's/^/      /'; fi

  echo; echo "==================== RESULT ===================="
  [ "$FAIL" = 0 ] && green "ALL CHECKS PASSED ($PASS pass)" || red "$FAIL FAILED / $PASS passed"
  echo "==============================================="
  [ "$FAIL" = 0 ]
}

cleanup(){ hdr "cleanup"; oc delete ns "$NS" --wait=false 2>/dev/null; rm -f "$STATE" "${STATE}".* 2>/dev/null; green "removed ns/$NS and state files"; }

case "${1:-}" in
  baseline) baseline ;;
  verify)   verify ;;
  cleanup)  cleanup ;;
  *) echo "usage: $0 {baseline|verify|cleanup}"; echo "  KUBECONFIG must point at the cluster."; exit 2 ;;
esac
