#!/bin/bash

set -euo pipefail

error()
{
	local command='/usr/bin/echo'
	local -a args=('-e')

	local -r light_red='\033[1;31m'
	local -r nocolor='\033[0m'
	args+=("${@}")
	args[1]="${light_red}${args[1]}${nocolor}"
	"${command}" "${args[@]}" 1>&2

	notify-send --expire-time 5000 \
		    "${0##*/}" \
		    "${*}"
}

if [ $# -eq 0 ]; then
	cat >&2 <<-EOF
	Usage: ${0##*/} [options] -t <template> -c <command>
	 -t, --template       Template VM
	 -c, --command        Exec inside qube
	Optional [defaults]:
	 -q, --qubename       Qube name [dispN], N is 100-9999
	 -n, --netvm          NetVM for qube [none]
	 -d, --tempdir        RAM drive Mountpoint [${HOME}/tmp/qubename]
	 -s, --tempsize       RAM drive size (GB) [2G]
	 -m, --memory         Qube memory in MB [1000]
	 -v, --default_dispvm Default disp template [none]
	 -k, --kernel         Kernel version [empty]
	 -l, --label          Label for the domain (yellow, red, ...) [yellow]
	 -e, --ephemeral      Ephemeral key (qvm-vol) [false]
	EOF
	exit 1
fi

tempdir_root="${HOME}/tmp"
netvm=''
tempsize='2G'
memory='1000'
default_dispvm=''
kernel="$(qubes-prefs default_kernel)"
label='yellow'
ephemeral='false'

while : ; do
	qube_name=$(/usr/bin/shuf --input-range=100-9999 --head-count=1)
	qube_name="disp${qube_name}"
	tempdir="${tempdir_root}/${qube_name}"
	[ -d "${tempdir}" ] && continue
	pool_name="ram_pool_${qube_name}"
	if ! qvm-check "${qube_name}" > /dev/null 2>&1; then
		break
	fi
done

set +u
while : ; do
	case "${1}" in
		-q | --qubename)
			if qvm-check "${2}" > /dev/null 2>&1; then
				error "${2}:" "already exists. Exiting."
				exit 1
			fi
			qube_name="${2}"
                        shift 2
                        ;;
		-t | --template)
                        template="${2}"
                        shift 2
                        ;;
		-c | --command)
                        command_to_run="${2}"
                        shift 2
                        ;;
                -n | --netvm)
                        netvm="${2}"
                        shift 2
                        ;;
		-d | --tempdir)
			if [ -d "${2}" ]; then
				error "${2}:" 'Directory exists'
				exit 1
			fi
			tempdir="${2}"
			shift 2
			;;
		-s | --tempsize)
			tempsize="${2}"
			shift 2
			;;
		-m | --memory)
			memory="${2}"
			shift 2
			;;
                -v | --default_dispvm)
                        default_dispvm="${2}"
                        shift 2
                        ;;
                -l | --label)
                        label="${2}"
                        shift 2
                        ;;
		-k | --kernel)
			kernel="${2}"
			shift 2
			;;
		-e | --ephemeral)
			if [[ "${2,,}" != 'true' ]]; then
				error "ephemeral:" "Can only be set to true."
				exit 1
			fi
			ephemeral="${2}"
                        shift 2
                        ;;
		--) # End of all options
			shift
			break;
			;;
		-*)
			error 'Unknown option:' "${1}"
			exit 1
			;;
		*)  # No more options
			break
			;;
	esac
done
set -u
sudo swapoff --all
mkdir --parents "${tempdir}"

sudo mount --types tmpfs \
	   --options size="${tempsize}" \
	   "${pool_name}" \
	   "${tempdir}"
qvm-pool add "${pool_name}" \
	 file \
	 --option revisions_to_keep=1 \
	 --option dir_path="${tempdir}"


logdir='/var/log'
logfiles=("${logdir}/libvirt/libxl/${qube_name}.log"
	  "${logdir}/qubes/guid.${qube_name}.log"
	  "${logdir}/qubes/qrexec.${qube_name}.log"
	  "${logdir}/qubes/qubesdb.${qube_name}.log"
	  "${logdir}/xen/console/guest-${qube_name}.log")
for file in "${logfiles[@]}"; do
	sudo ln -sfT /dev/null "${file}"
done

qvm-create --class DispVM \
	   "${qube_name}" \
	   -P "${pool_name}" \
	   --template="${template}" \
	   --property netvm="${netvm}" \
	   --property memory="${memory}" \
	   --property default_dispvm="${default_dispvm}" \
	   --property kernel="${kernel}" \
	   --property label="${label}"

if [[ "${ephemeral,,}" == 'true' ]]; then
	qvm-volume config "${qube_name}":root rw 0
	qvm-volume config "${qube_name}":private rw 0
	qvm-volume config "${qube_name}":volatile ephemeral 1
fi
###
set +e
qvm-run "${qube_name}" "${command_to_run}"
set -e

qvm-kill "${qube_name}"
qvm-remove --force "${qube_name}"
qvm-pool remove "${pool_name}"
sudo umount "${pool_name}"

sudo shred -n 20 -zuvf "${tempdir}"
for file in "${logfiles[@]}"; do
        sudo shred -n 20 -zuvf "${file}" "${file}.old"
done

set +e
rmdir "${tempdir_root}"
set -e

notify-send --expire-time 5000 \
	    "${qube_name} qube" \
	    "${qube_name} qube remnants cleared."