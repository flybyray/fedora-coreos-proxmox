#!/bin/bash
set -xveuo pipefail
IFS=$'\n\t'

vmid="$1"
phase="$2"

# global vars
COREOS_TMPLT=/opt/fcos-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/geco-pve/coreos
YQ="/usr/local/bin/yq read --exitStatus --printMode v --stripComments --"

# ==================================================================================================================================================================
# functions()
#
setup_fcoreosct() {
	local CT_VER=0.7.0
	local ARCH=x86_64
	local OS=unknown-linux-gnu # Linux
	local DOWNLOAD_URL=https://github.com/coreos/fcct/releases/download

	[[ -x /usr/local/bin/fcos-ct ]] && [[ "$(/usr/local/bin/fcos-ct --version | awk '{print $NF}' || true)" == "${CT_VER}" ]] && return 0
	echo "Setup Fedora CoreOS config transpiler..."
	rm -f /usr/local/bin/fcos-ct
	wget --quiet --show-progress "${DOWNLOAD_URL}/v${CT_VER}/fcct-${ARCH}-${OS}" -O /usr/local/bin/fcos-ct
	chmod 755 /usr/local/bin/fcos-ct
}
setup_fcoreosct

setup_yq() {
	local VER=3.4.1

	[[ -x /usr/bin/wget ]] && download_command="/usr/bin/wget --quiet --show-progress --output-document" || download_command="curl --location --output"
	[[ -x /usr/local/bin/yq ]] && [[ "$(/usr/local/bin/yq --version | awk '{print $NF}' || true)" == "${VER}" ]] && return 0
	echo "Setup yaml parser tools yq..."
	rm -f /usr/local/bin/yq
	${download_command} "/usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/${VER}/yq_linux_amd64"
	chmod 755 /usr/local/bin/yq
}
setup_yq

# ==================================================================================================================================================================
# main()
#
if [[ "${phase}" == "pre-start" ]]; then
	instance_id="$(qm cloudinit dump "${vmid}" meta | ${YQ} - 'instance-id')"

	# same cloudinit config ?
	[[ -e "${COREOS_FILES_PATH}/${vmid}.id" ]] && [[ "x${instance_id}" != "x$(cat "${COREOS_FILES_PATH}/${vmid}.id" || true)" ]] && {
		rm -f "${COREOS_FILES_PATH}/${vmid}.ign" # cloudinit config change
	}
	[[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]] && exit 0 # already done

	mkdir -p "${COREOS_FILES_PATH}" || exit 1

	# check config
	cipasswd="$(qm cloudinit dump "${vmid}" user | ${YQ} - 'password' 2>/dev/null)" || true # can be empty
	[[ "x${cipasswd}" != "x" ]] && VALIDCONFIG=true
	${VALIDCONFIG:-false} || [[ $(qm cloudinit dump "${vmid}" user | ${YQ} - 'ssh_authorized_keys[*]' || true) == "" ]] || VALIDCONFIG=true
	${VALIDCONFIG:-false} || {
		echo "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
		exit 1
	}

	echo -n "Fedora CoreOS: Generate yaml users block... "
	ciuser="$(qm cloudinit dump "${vmid}" user 2>/dev/null | grep '^user:' | awk '{print $NF}')"
	{
		echo -e "# This file is managed by Geco-iT hook-script. Do not edit.\n"
		echo -e "variant: fcos\nversion: 1.1.0"
		echo -e "# user\npasswd:\n  users:"
		echo "    - name: \"${ciuser:-admin}\""
		echo "      gecos: \"Geco-iT CoreOS Administrator\""
		echo "      password_hash: '${cipasswd}'"
		echo '      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]'
		echo '      ssh_authorized_keys:'
		qm cloudinit dump "${vmid}" user | ${YQ} - 'ssh_authorized_keys[*]' | sed -e 's/^/        - "/' -e 's/$/"/'
		echo
	} >"${COREOS_FILES_PATH}/${vmid}.yaml"
	echo "[done]"

	echo -n "Fedora CoreOS: Generate yaml hostname block... "
	hostname="$(qm cloudinit dump "${vmid}" user | ${YQ} - 'hostname' 2>/dev/null)"
	{
		echo -e "# network\nstorage:\n  files:"
		echo "    - path: /etc/hostname"
		echo "      mode: 0644"
		echo "      overwrite: true"
		echo "      contents:"
		echo "        inline: |"
		echo -e "          ${hostname,,}\n"
	} >>"${COREOS_FILES_PATH}/${vmid}.yaml"
	echo "[done]"

	echo -n "Fedora CoreOS: Generate yaml network block... "
	netcards="$(qm cloudinit dump "${vmid}" network | ${YQ} - 'config[*].name' 2>/dev/null | wc -l)"
	nameservers="$(qm cloudinit dump "${vmid}" network | ${YQ} - "config[${netcards}].address[*]" | paste -s -d ";" -)"
	searchdomain="$(qm cloudinit dump "${vmid}" network | ${YQ} - "config[${netcards}].search[*]" | paste -s -d ";" -)"
	for ((i = O; i < netcards; i++)); do
		ipv4="" netmask="" gw="" macaddr=""                                                                               # reset on each run
		ipv4="$(qm cloudinit dump "${vmid}" network | ${YQ} - "config[${i}].subnets[0].address" 2>/dev/null)" || continue # dhcp
		netmask="$(qm cloudinit dump "${vmid}" network | ${YQ} - "config[${i}].subnets[0].netmask" 2>/dev/null)"
		gw="$(qm cloudinit dump "${vmid}" network | ${YQ} - "config[${i}].subnets[0].gateway" 2>/dev/null)" || true # can be empty
		macaddr="$(qm cloudinit dump "${vmid}" network | ${YQ} - "config[${i}].mac_address" 2>/dev/null)"
		# ipv6: TODO

		{
			echo "    - path: /etc/NetworkManager/system-connections/net${i}.nmconnection"
			echo "      mode: 0600"
			echo "      overwrite: true"
			echo "      contents:"
			echo "        inline: |"
			echo "          [connection]"
			echo "          type=ethernet"
			echo "          id=net${i}"
			echo "          #interface-name=eth${i}"
			echo
			echo "          [ethernet]"
			echo "          mac-address=${macaddr}"
			echo
			echo "          [ipv4]"
			echo "          method=manual"
			echo "          addresses=${ipv4}/${netmask}"
			echo "          gateway=${gw}"
			echo "          dns=${nameservers}"
			echo "          dns-search=${searchdomain}"
			echo
		} >>"${COREOS_FILES_PATH}/${vmid}.yaml"
	done
	echo "[done]"

	[[ -e "${COREOS_TMPLT}" ]] && {
		echo -n "Fedora CoreOS: Generate other block based on template... "
		cat "${COREOS_TMPLT}" >>"${COREOS_FILES_PATH}/${vmid}.yaml"
		echo "[done]"
	}

	echo -n "Fedora CoreOS: Generate ignition config... "
	if /usr/local/bin/fcos-ct --pretty --strict \
		--output "${COREOS_FILES_PATH}/${vmid}.ign" \
		"${COREOS_FILES_PATH}/${vmid}.yaml" 2>/dev/null; then
		echo "[done]"
	else
		echo "[failed]"
		exit 1
	fi

	# save cloudinit instanceid
	echo "${instance_id}" >"${COREOS_FILES_PATH}/${vmid}.id"

	# check vm config (no args on first boot)
	qm config "${vmid}" --current | grep -q ^args || {
		echo -n "Set args com.coreos/config on VM${vmid}... "
		rm -f "/var/lock/qemu-server/lock-${vmid}.conf"
		if pvesh set "/nodes/$(hostname)/qemu/${vmid}/config" --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2>/dev/null
		then touch "/var/lock/qemu-server/lock-${vmid}.conf"
		else echo "[failed]"; exit 1
		fi

		# hack for reload new ignition file
		echo -e "\nWARNING: New generated Fedora CoreOS ignition settings, we must restart vm..."
		qm stop "${vmid}" && sleep 2 && qm start "${vmid}" &
		exit 1
	}
fi

exit 0
