#!/usr/bin/env bash
# Download the papers listed in README.md into the per-library folders next to this script.
#
# Usage: ./download.sh [-f|--force] [-n|--dry-run] [DEST]
#   DEST           root folder to download into (default: the folder this script is in)
#   -f, --force    re-download files that already exist (an existing file is only replaced
#                  once the new download has been checked to be a PDF)
#   -n, --dry-run  print what would be downloaded and exit
#
# Notes
# - arXiv entries fetch the latest arXiv version. Our walberla/walberla-a-block-structured.pdf is
#   the publisher's (Elsevier) version; the script saves the arXiv preprint under the same name.
# - Two papers cannot be fetched by a script and are reported as MANUAL, with the page to get them
#   from: the SC'19 pystencils paper (the ACM Digital Library answers scripts with 403) and
#   Risso et al., SBAC-PAD 2019 (the SBC library serves a bot check). Both are still tried, and a
#   file is only kept if it really is a PDF.
# - cerfacs.fr (Holzer thesis) sends an incomplete TLS certificate chain. The script then fetches
#   the missing intermediate certificate from the address the server certificate names, checks
#   that it chains to a root in the system CA store, and retries with it. TLS verification is
#   never turned off.

set -euo pipefail

# subfolder | file name | download URL | where to get it by hand if the script can't (optional)
PAPERS=(
  "pystencils|pystencil.pdf|https://dl.acm.org/doi/pdf/10.1145/3295500.3356186|https://doi.org/10.1145/3295500.3356186 (ACM Digital Library, in a browser)"
  "pystencils|hennig-cecam2024-pystencils-lbmpy-slides.pdf|https://members.cecam.org/storage/presentation/thu_hennig_pystencils-1728672352.pdf|"
  "pystencils|pystencils-gpu-perfmodel-jpdc2023-arxiv2204.14242.pdf|https://arxiv.org/pdf/2204.14242|"
  "lbmpy|lbmpy-jocs2021-arxiv2001.11806.pdf|https://arxiv.org/pdf/2001.11806|"
  "lbmpy|lbmpy-mrt-cumulant-sisc2023-arxiv2211.02435.pdf|https://arxiv.org/pdf/2211.02435|"
  "lbmpy|lbmpy-multiphase-ijhpca2021-arxiv2012.06144.pdf|https://arxiv.org/pdf/2012.06144|"
  "lbmpy|lbmpy-sparse-ijhpca2026-arxiv2408.06880.pdf|https://arxiv.org/pdf/2408.06880|"
  "lbmpy|holzer-phd-thesis-2024.pdf|https://cerfacs.fr/wp-content/uploads/2024/11/Phd_HOLZER_Markus.pdf|"
  "walberla|walberla-a-block-structured.pdf|https://arxiv.org/pdf/1909.13772|"
  "walberla|walberla-wind-preprint.pdf|https://arxiv.org/pdf/2402.13171|"
  "walberla|mesapd-dem8-arxiv1906.10963.pdf|https://arxiv.org/pdf/1906.10963|"
  "walberla|Scalable_GPU_Communication_with_Code_Generation_on_Stencil_Applications.pdf|https://sol.sbc.org.br/index.php/sbac-pad/article/download/35010/34801|https://sol.sbc.org.br/index.php/sbac-pad/article/view/35010 in a browser, or IEEE Xplore: https://doi.org/10.1109/SBAC-PAD.2019.00026"
  "kerncraft|kerncraft-2017-arxiv1702.04653.pdf|https://arxiv.org/pdf/1702.04653|"
  "exastencils|exastencils-walberla-octree-multigrid-arxiv2403.08063.pdf|https://arxiv.org/pdf/2403.08063|"
)

UA="Mozilla/5.0 (X11; Linux x86_64) paper-fetch/1.0"
PAUSE=3   # seconds between requests, to be polite to arXiv

force=0
dry=0
dest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force)   force=1 ;;
    -n|--dry-run) dry=1 ;;
    -h|--help)    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           echo "unknown option: $1" >&2; exit 2 ;;
    *)            dest="$1" ;;
  esac
  shift
done
[[ -n "$dest" ]] || dest="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

is_pdf() { [[ -s "$1" && "$(head -c 5 "$1")" == "%PDF-" ]]; }

system_ca_bundle() {
  local f
  for f in /etc/ssl/certs/ca-certificates.crt \
           /etc/ca-certificates/extracted/tls-ca-bundle.pem \
           /etc/pki/tls/certs/ca-bundle.crt \
           /etc/ssl/cert.pem; do
    [[ -s "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# For a host whose server leaves out its intermediate certificate: fetch that intermediate from the
# "CA Issuers" address in the server certificate, check that it chains to a trusted root, and print
# the path of a CA bundle (system CAs + intermediate) for curl --cacert.
chain_fix_bundle() {
  local host=$1 sys leaf inter aia
  command -v openssl >/dev/null || return 1
  sys="$(system_ca_bundle)" || return 1
  leaf="$TMP/$host.leaf.pem"
  inter="$TMP/$host.inter.pem"
  openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null \
    | openssl x509 >"$leaf" 2>/dev/null || return 1
  aia="$(openssl x509 -in "$leaf" -noout -text \
         | sed -n 's/.*CA Issuers - URI:\([^ ]*\).*/\1/p' | head -1)"
  [[ -n "$aia" ]] || return 1
  curl -sSL --fail --max-time 60 -o "$TMP/$host.inter.raw" "$aia" || return 1
  openssl x509 -inform DER -in "$TMP/$host.inter.raw" -out "$inter" 2>/dev/null \
    || openssl x509 -in "$TMP/$host.inter.raw" -out "$inter" 2>/dev/null || return 1
  openssl verify -CAfile "$sys" -untrusted "$inter" "$leaf" >/dev/null 2>&1 || return 1
  cat "$sys" "$inter" >"$TMP/$host.bundle.pem"
  echo "$TMP/$host.bundle.pem"
}

# fetch URL OUT: download to OUT.part, keep it as OUT only if it is a PDF.
fetch() {
  local url=$1 out=$2 part="$2.part" rc=0 host bundle
  rm -f "$part"
  curl -sSL --fail -A "$UA" --max-time 300 --retry 2 -o "$part" "$url" 2>"$TMP/curl.err" || rc=$?
  if [[ $rc -eq 60 ]]; then   # 60 = server certificate could not be verified
    host="$(sed -E 's#^https://([^/]+).*#\1#' <<<"$url")"
    if bundle="$(chain_fix_bundle "$host")"; then
      echo "    (incomplete certificate chain from $host, retrying with its verified intermediate)"
      rc=0
      curl -sSL --fail -A "$UA" --max-time 300 --retry 2 --cacert "$bundle" \
        -o "$part" "$url" 2>"$TMP/curl.err" || rc=$?
    fi
  fi
  if [[ $rc -eq 0 ]] && is_pdf "$part"; then
    mv -f "$part" "$out"
    return 0
  fi
  rm -f "$part"
  if [[ $rc -ne 0 ]]; then
    echo "    curl exit $rc: $(tr '\n' ' ' <"$TMP/curl.err")"
  else
    echo "    the server did not return a PDF"
  fi
  return 1
}

ok=() skipped=() failed=() manual=()
first=1
for entry in "${PAPERS[@]}"; do
  IFS='|' read -r sub name url by_hand <<<"$entry"
  out="$dest/$sub/$name"
  if [[ -e "$out" && $force -eq 0 ]]; then
    skipped+=("$sub/$name")
    continue
  fi
  if [[ $dry -eq 1 ]]; then
    echo "would get $sub/$name  <-  $url"
    continue
  fi
  mkdir -p "$dest/$sub"
  [[ $first -eq 1 ]] || sleep "$PAUSE"
  first=0
  echo "get $sub/$name"
  if fetch "$url" "$out"; then
    ok+=("$sub/$name")
  elif [[ -n "$by_hand" ]]; then
    manual+=("$sub/$name: $by_hand")
  else
    failed+=("$sub/$name  <-  $url")
  fi
done

[[ $dry -eq 1 ]] && { echo "(dry run, ${#skipped[@]} already present)"; exit 0; }

echo
echo "downloaded: ${#ok[@]}   already present: ${#skipped[@]}   manual: ${#manual[@]}   failed: ${#failed[@]}"
for m in "${manual[@]}"; do echo "  MANUAL  $m"; done
for f in "${failed[@]}"; do echo "  FAILED  $f"; done
[[ ${#failed[@]} -eq 0 ]]
