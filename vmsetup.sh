#!/bin/bash
if [[ -n "${DEBUG+x}" ]]; then
        set -x
fi
if [[ -n "${TRACE+x}" ]]; then
        set -v
fi
set -euo pipefail
IFS=$'\n\t'

# Cleanup trap
cleanup() {
        # Add cleanup code here
        echo "Cleaning up..."
        rm -f "${STREAM}.json"
        rm -f "meta.json"
        rm -f "temporary_keyring.gpg"*
        rm -f "fedora.gpg"
}

trap cleanup EXIT

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

if [[ -f "$(dirname "${BASH_SOURCE[0]}")/template_config.conf" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/template_config.conf"
else
        TEMPLATE_VMID="900"          # Template Proxmox VMID
        TEMPLATE_VMSTORAGE="local"   # Proxmox storage
        SNIPPET_STORAGE="local"      # Snippets storage for hook and ignition file
        VMDISK_OPTIONS=",discard=on" # Add options to vmdisk

        TEMPLATE_IGNITION="fcos-base-tmplt.yaml"
        TEMPLATE_NET0_BRIDGE="vmbr0"

        STREAM="stable"
        VERSION="39.20240210.3.0"
        PLATFORM=qemu
        BASEURL=https://builds.coreos.fedoraproject.org
fi

if [[ "${VERSION}" == "LATEST" ]]; then
        curl -L -o "${STREAM}.json" "${BASEURL}/streams/${STREAM}.json"
        VERSION="$(jq -r '.architectures.'"${ARCHITECTURE}"'.artifacts.'"${PLATFORM}"'.release' <"${STREAM}.json")"
        COREOS_LOCATION="$(jq -r '.architectures.'"${ARCHITECTURE}"'.artifacts.'"${PLATFORM}"'.formats."qcow2.xz".disk.location' <"${STREAM}.json")"
        COREOS_SIGNATURE="$(jq -r '.architectures.'"${ARCHITECTURE}"'.artifacts.'"${PLATFORM}"'.formats."qcow2.xz".disk.signature' <"${STREAM}.json")"
        COREOS_SHA256="$(jq -r '.architectures.'"${ARCHITECTURE}"'.artifacts.'"${PLATFORM}"'.formats."qcow2.xz".disk.sha256' <"${STREAM}.json")"
        COREOS_UNCOMPRESSED_SHA256="$(jq -r '.architectures.'"${ARCHITECTURE}"'.artifacts.'"${PLATFORM}"'.formats."qcow2.xz".disk."uncompressed-sha256"' <"${STREAM}.json")"
else
        curl -L -o "meta.json" "https://builds.coreos.fedoraproject.org/prod/streams/${STREAM}/builds/${VERSION}/${ARCHITECTURE}/meta.json"
        COREOS_LOCATION="https://builds.coreos.fedoraproject.org/prod/streams/${STREAM}/builds/${VERSION}/${ARCHITECTURE}/$(jq -r '.images.'"${PLATFORM}"'.path' <"meta.json")"
        COREOS_SIGNATURE="https://builds.coreos.fedoraproject.org/prod/streams/${STREAM}/builds/${VERSION}/${ARCHITECTURE}/$(jq -r '.images.'"${PLATFORM}"'.path' <"meta.json").sig"
        COREOS_SHA256="$(jq -r '.images.'"${PLATFORM}"'.sha256' <"meta.json")"
        COREOS_UNCOMPRESSED_SHA256="$(jq -r '.images.'"${PLATFORM}"'."uncompressed-sha256"' <"meta.json")"
fi

# =============================================================================================
# main()

# pve storage exist ?
echo -n "Check if vm storage ${TEMPLATE_VMSTORAGE} exist... "
pvesh get "/storage/${TEMPLATE_VMSTORAGE}" --noborder --noheader &>/dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet ok ?
echo -n "Check if snippet storage ${SNIPPET_STORAGE} exist... "
pvesh get "/storage/${SNIPPET_STORAGE}" --noborder --noheader &>/dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet enable
pvesh get "/storage/${SNIPPET_STORAGE}" --noborder --noheader | grep snippets || {
        echo "You must activate content snippet on storage: ${SNIPPET_STORAGE}"
        exit 1
}

# copy files
echo "Copy hook-script and ignition config to snippet storage..."
snippet_storage="$(pvesh get "/storage/${SNIPPET_STORAGE}" --noborder --noheader | grep -Po '^path\s+\K.+(?=\s*$)')"
echo "${snippet_storage}"
cp -av "${TEMPLATE_IGNITION}" hook-fcos.sh "${snippet_storage}/snippets"
sed -e "/^COREOS_TMPLT/ c\COREOS_TMPLT=${snippet_storage}/snippets/${TEMPLATE_IGNITION}" -i "${snippet_storage}/snippets/hook-fcos.sh"
chmod 755 "${snippet_storage}/snippets/hook-fcos.sh"

# storage type ? (https://pve.proxmox.com/wiki/Storage)
echo -n "Get storage \"${TEMPLATE_VMSTORAGE}\" type... "
case "$(pvesh get "/storage/${TEMPLATE_VMSTORAGE}" --noborder --noheader | grep -Po '^type\s+\K.+(?=\s*$)')" in
dir | nfs | cifs | glusterfs | cephfs)
        echo "[file]"
        vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.qcow2"
        vmdisk_format="--format qcow2"
        ;;
lvm | lvmthin | iscsi | iscsidirect | rbd | zfs | zfspool)
        echo "[block]"
        vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
        ;;
*)
        echo "[unknown]"
        exit 1
        ;;
esac

# download fcos vdisk
fedora_coreos_compressed_image="$(basename "${COREOS_LOCATION}")"
if [[ ! -f "${fedora_coreos_compressed_image%.xz}" ]]; then
        for url in "${COREOS_LOCATION}" "${COREOS_SIGNATURE}"; do
                base_name="$(basename "${url}")"
                if [[ ! -f "${base_name}" ]]; then
                        curl -L -o "${base_name}" "${url}"
                fi
        done
        if [[ ! -f "fedora.gpg" ]]; then curl -L -O https://fedoraproject.org/fedora.gpg; fi
        gpg --no-default-keyring --keyring ./temporary_keyring.gpg --import ./fedora.gpg
        gpg --no-default-keyring --keyring ./temporary_keyring.gpg --verify "${fedora_coreos_compressed_image}".sig "${fedora_coreos_compressed_image}"
        sha256sum -c <<EOF 2>&1 | grep OK
${COREOS_SHA256}  ${fedora_coreos_compressed_image}
EOF
        xz -dv "${fedora_coreos_compressed_image}"
        sha256sum -c <<EOF 2>&1 | grep OK
${COREOS_UNCOMPRESSED_SHA256}  ${fedora_coreos_compressed_image%.xz}
EOF
fi

# create a new VM
echo "Create fedora coreos vm ${TEMPLATE_VMID}"
qm create "${TEMPLATE_VMID}" --name "${TEMPLATE_NAME}"
qm set "${TEMPLATE_VMID}" --memory 4096 \
        --cpu host \
        --cores 4 \
        --agent enabled=1 \
        --autostart \
        --onboot 1 \
        --ostype l26 \
        --tablet 0 \
        --boot c --bootdisk scsi0

template_vmcreated=$(date +%Y-%m-%d)
qm set "${TEMPLATE_VMID}" --description "Fedora CoreOS

 - Version             : ${VERSION}
 - Cloud-init          : true

Creation date : ${template_vmcreated}
"

qm set "${TEMPLATE_VMID}" --net0 "virtio,bridge=${TEMPLATE_NET0_BRIDGE}"

echo -e "\nCreating Cloud-init vmdisk..."
qm set "${TEMPLATE_VMID}" --ide2 "${TEMPLATE_VMSTORAGE}:cloudinit"

# import fedora disk
if [[ -n "${vmdisk_format+x}" ]]; then
        qm importdisk "${TEMPLATE_VMID}" "fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2" "${TEMPLATE_VMSTORAGE}" "${vmdisk_format}"
else
        qm importdisk "${TEMPLATE_VMID}" "fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2" "${TEMPLATE_VMSTORAGE}"
fi

qm set "${TEMPLATE_VMID}" --scsihw virtio-scsi-pci --scsi0 "${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}"

# set hook-script
qm set "${TEMPLATE_VMID}" -hookscript "${SNIPPET_STORAGE}:snippets/hook-fcos.sh"

# convert vm template
echo -n "Converting VM ${TEMPLATE_VMID} in proxmox vm template... "
qm template "${TEMPLATE_VMID}" &>/dev/null || true
echo "[done]"
