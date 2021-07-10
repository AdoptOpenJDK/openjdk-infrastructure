#!/bin/bash

ARCHITECTURE=""
OS=""
skipFullSetup=""
gitFork="adoptopenjdk"
gitBranch="master"
PORTNO=10022
if [ "$EXECUTOR_NUMBER" ]; then
  PORTNO=1002$EXECUTOR_NUMBER
fi
current_dir=false
cleanWorkspace=false
retainVM=false
buildJDK=false
buildFork="adoptopenjdk"
buildBranch="master"
buildVariant=""
testJDK=false
# Default to building jdk8u
jdkToBuild="jdk8u"

# Parse Arguments
processArgs() {
	while [[ $# -gt 0 ]] && [[ ."$1" = .-* ]]; do
		local opt="$1";
		shift;
		case "$opt" in
			"--architecture" | "-a" )
				ARCHITECTURE="$1"; shift;;			
			"--build" | "-b" )
				buildJDK=true;;
			"--build-fork" | "-bf" )
				buildFork="$1"; shift;;
			"--build-branch" | "-bb" )
				buildBranch="$1"; shift;;
			"--build-hotspot" | "-hs" )
				buildVariant="--hotspot";;
			"--currentDir " | "-c" )
				current_dir=true;;
			"--clean-workspace" | "-cw" )
				cleanWorkspace=true;;
			"--help" | "-h" )
				usage; exit 0;;
			"--retainVM" | "-r" )
				retainVM=true;;
			"--test" | "-t" )
				testJDK=true;;
			"--infra-fork" | "-if" )
				gitFork="$1"; shift;;
			"--infra-branch" | "-ib" )
				gitBranch=$1; shift;;
			"--skip-more" | "-sm" )
				skipFullSetup=",nvidia_cuda_toolkit,MSVS_2010,MSVS_2017";;
			"--operating-system" | "-o")
				OS="$1"; shift;;
			"--jdk-version" | "-v" )
				jdkToBuild="$1"; shift;;
			*) echo >&2 "Invalid option: ${opt}"; echo "This option was unrecognised."; usage; exit 1;;
		esac
	done
}

usage() {
	echo "Usage: ./qemu_test_script.sh (<options>) -a <architecture> -o <os>
		--architecture | -a		Specifies the architecture to build the OS on
		--build | -b			Build a JDK on the qemu VM
		--build-fork | -bf		Which openjdk-build to retrieve the build scripts from
		--build-branch | -bb		Specify the branch of the build-repo (default: master)
		--build-hotspot | -hs			Build a JDK with a Hotspot JVM instead of an OpenJ9 one
		--currentDir | -c		Set Workspace to directory of this script
		--clean-workspace | -cw		Removes the old work folder (including logs)
		--help | -h 			Shows this help message
		--infra-fork | -if		Which openjdk-infrastructure to retrieve the playbooks (default: adoptopenjdk)
		--infra-branch | -ib		Specify the branch of the infra-repo (default: master)
		--jdk-version | -v		Specify which JDK to build if '-b' is used (default: jdk8u)
		--retainVM | -r			Retain the VM once running the playbook
		--operating-system | -o 	Combined with --architecture runs a VM with the desired architecture and OS combo.
		--skip-more | -sm		Skip non-essential roles from the playbook
		--test | -t			Test the built JDK
		"	
	showArchList
}

defaultVars() {
	case "$ARCHITECTURE" in
		"s390x" | "S390X" | "S390x" )
			ARCHITECTURE=S390X;;
		"aarch64" | "arm64" | "ARM64" )
			ARCHITECTURE=AARCH64;;
		"ppc64le" | "ppc64" | "PPC64LE" | "PPC64" )
			ARCHITECTURE=PPC64LE;;
		"arm32" | "ARM32" | "armv7l" | "ARMV7L")
			ARCHITECTURE=ARM32;;
		"RISC-V" | "riscv" | "risc-v" | "RISCV" )
			ARCHITECTURE=RISCV;;
		"" )
			echo "Please input an architecture to test"; exit 1;;
		*) echo "Please select a valid architecture"; showArchList; exit 1;;
	esac

	case "$OS" in
		"debian8" | "Debian8" | "deb8" )
			echo "DEBIAN8 selected for $ARCHITECTURE"; OS=DEBIAN8;;
		"debian10" | "Debian10" | "deb10" )
			echo "DEBIAN10 selected for $ARCHITECTURE"; OS=DEBIAN10;;
		"ubuntu18" | "u18" | "Ubuntu18" )
			echo "UBUNTU18 selected for $ARCHITECTURE"; OS=UBUNTU18;;
		"debian11" | "deb11" | "Debian11" )
			echo "DEBIAN11 selected for $ARCHITECTURE"; OS=DEBIAN11;;
		* )
			echo "Please use the -o flag to select a supported OS"; showArchList; exit 1;;
	esac

	if [[ -z "${WORKSPACE:-}" && "$current_dir" == false ]] ; then
		echo "WORKSPACE not found, setting it as environment variable 'HOME'"
		WORKSPACE=$HOME
	elif [[ "$current_dir" = true ]]; then
		echo "Setting WORKSPACE to the current directory"
		WORKSPACE=$PWD	
	fi
	if [[ "$buildJDK" == false && "$testJDK" == true ]]; then
		echo "Unable to test an unbuilt JDK. Please specify both '--build' and '--test'."
		exit 1;
	fi
	if [[ "$buildJDK" == true && "$ARCHITECTURE" == "RISCV" ]]; then
		if [ "$buildVariant" = "hotspot" ]; then
			echo "Cannot build the main hotspot directly on RISC-V so selecting Bisheng variant"
			buildVariant=bisheng
		else
			echo "Currently unable to build a JDK on RISC-V natively"
			echo "Skipping build/test"
			buildJDK=false
			testJDK=false
		fi
	fi

}

showArchList() {
	echo "Currently supported architectures and operating systems:
	- ppc64le
		- Ubuntu18
	- s390x
		- Ubuntu18
	- arm32
		- Debian8
	- aarch64
		- Debian10
		- Ubuntu18
	- riscv
		- Debian11"
}

# Setup the file system

setupWorkspace() {
	local workFolder=$WORKSPACE/qemu_pbCheck
	# Images are in this consistent place on the 'vagrant' jenkins machines
	local imageLocation="/home/jenkins/qemu_base_images"

	if [[ ! -f "$imageLocation/${OS}.${ARCHITECTURE}/${OS}.${ARCHITECTURE}.dsk.xz" ]]; then
		echo "Either this script does not support ${OS} on ${ARCHITECTURE}, or the disk image is not in $imageLocation"
		exit 1;
	fi
	
	mkdir -p "$workFolder"/logFiles
	if [[ "$cleanWorkspace" = true ]]; then
		echo "Cleaning old workspace"
		# finds all non-dir files and deletes them
		find "$workFolder" -type f | xargs rm -f
		rm -rf "$workFolder"/openjdk-infrastructure "$workFolder"/openjdk-build
	fi
	if [[ ! -f "${workFolder}/${OS}.${ARCHITECTURE}.dsk" ]]; then 
		echo "Copying new disk image"
		# Copy disk image and tools from imageLocation to workFolder
		cp -r $imageLocation/$OS.$ARCHITECTURE/. $workFolder
		xz -d "$workFolder"/"$OS.$ARCHITECTURE".dsk.xz
	else
		echo "Using old disk image"
	fi
}

runImage() {

local EXTRA_ARGS=""
local workFolder="$WORKSPACE/qemu_pbCheck"

# Find/stop port collisions
while netstat -lp 2>/dev/null | grep "tcp.*:$PORTNO " > /dev/null; do
  ((PORTNO++))
done
	echo "Using Port: $PORTNO"

	# Setting architecture specific variables
	case "$ARCHITECTURE" in
		"S390X" )
			export MACHINE="s390-ccw-virtio"
			export DRIVE="-drive file=$workFolder/${OS}.${ARCHITECTURE}.dsk,if=none,id=hd0 -device virtio-blk-ccw,drive=hd0,id=virtio-disk0"
			export QEMUARCH="s390x"
			export SSH_CMD="-net user,hostfwd=tcp::$PORTNO-:22 -net nic";;
		"PPC64LE" )
			export MACHINE="pseries-2.12"
			export DRIVE="-hda $workFolder/${OS}.${ARCHITECTURE}.dsk"
			export QEMUARCH="ppc64"
			export SSH_CMD="-net user,hostfwd=tcp::$PORTNO-:22 -net nic";;
		"AARCH64" )
			export QEMUARCH="aarch64"
			case $OS in
				"UBUNTU18" )
					export MACHINE="virt,gic-version=max"
					export DRIVE="-drive file=$workFolder/${OS}.${ARCHITECTURE}.dsk,if=none,id=drive0,cache=writeback -device virtio-blk,drive=drive0,bootindex=0"
					export SSH_CMD="-netdev user,id=vnet,hostfwd=:127.0.0.1:$PORTNO-:22 -device virtio-net-pci,netdev=vnet"
					export EXTRA_ARGS="-drive file=$workFolder/QEMU_EFI-flash.img,format=raw,if=pflash -drive file=$workFolder/flash1.img,format=raw,if=pflash -cpu max";;
				"DEBIAN10" )
					export MACHINE="virt"
					export DRIVE="-drive if=none,file=$workFolder/${OS}.${ARCHITECTURE}.dsk,id=hd -device virtio-blk-device,drive=hd"
					export SSH_CMD="-device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORTNO-:22"
					export EXTRA_ARGS="-cpu cortex-a57 -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd";;
			esac ;;
		"ARM32" )
			export MACHINE="virt"
			export QEMUARCH="arm"
			export SSH_CMD="-device virtio-net-device,netdev=mynet -netdev user,id=mynet,hostfwd=tcp::$PORTNO-:22"
			export DRIVE="-drive if=none,file=$workFolder/${OS}.${ARCHITECTURE}.dsk,format=qcow2,id=hd -device virtio-blk-device,drive=hd"
			export EXTRA_ARGS="-kernel $workFolder/kernel.arm32 -initrd $workFolder/initrd.arm32 -append root=/dev/vda2";;
		"RISCV" )
			export QEMUARCH="riscv64"
			export MACHINE="virt"
			export DRIVE="-device virtio-blk-device,drive=hd -drive file=$workFolder/${OS}.${ARCHITECTURE}.dsk,if=none,id=hd"
			export SSH_CMD="-device virtio-net-device,netdev=net -netdev user,id=net,hostfwd=tcp::$PORTNO-:22"
			export EXTRA_ARGS="-kernel /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.elf -device loader,file=/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin,addr=0x80200000";;
	esac
	
	# Run the command, mask output and send to background
	(qemu-system-$QEMUARCH \
	  -smp 4 \
	  -m 3072 \
     	  -M $MACHINE \
	  $SSH_CMD \
	  $DRIVE \
     	  $EXTRA_ARGS \
	  -nographic) > "$workFolder/${OS}.${ARCHITECTURE}.startlog" 2>&1 &

	echo "Machine is booting; logging console to $workFolder/${OS}.${ARCHITECTURE}.startlog"
	echo "Please be patient - this can take up to 300 seconds"

	SECONDS=0
	while [ true ];
	do
		if tail "$workFolder/${OS}.${ARCHITECTURE}.startlog" | grep -q login; then
			echo "VM Booted after $SECONDS seconds"
			break;
		fi
		if [ $SECONDS -gt 300 ]; then
			echo -e "Timeout Reached. See log below:\n"
			tail "$workFolder/${OS}.${ARCHITECTURE}.startlog" | sed 's/^/CONSOLE > /g'
			echo
			if [[ "$retainVM" == false ]]; then
				destroyVM
				echo "Removing disk image"
				rm -f ${workFolder}/${OS}.${ARCHITECTURE}.dsk
			fi
			exit 127
		fi
		sleep 10
	done
	# Remove old ssh key and create a new one
	rm -f "$workFolder"/id_rsa*
	ssh-keygen -q -f "$workFolder"/id_rsa -t rsa -N ''
        ssh-keygen -q -R "[localhost]:$PORTNO"

	# Required to auto-accept the host ECDSA key
	sshpass -p 'password' ssh linux@localhost -p "$PORTNO" -o StrictHostKeyChecking=no 'uname -a' 
	# Add ssh key to VM's authorized_keys
	sshpass -p 'password' ssh-copy-id -p "$PORTNO" -i "$workFolder"/id_rsa.pub linux@localhost 
}

## Run the playbook ( and build/test the JDK if applicable )

runPlaybook() {
	local workFolder="$WORKSPACE"/qemu_pbCheck
	local pbLogPath="$workFolder/logFiles/$OS.$ARCHITECTURE.log"
	local extraAnsibleArgs=""
        local gitURL="https://github.com/$gitFork/openjdk-infrastructure"

	# RISCV requires this be specified
	if [[ $ARCHITECTURE == "RISCV" ]]; then
		# To fix the outdated repositories of the image
		ssh -p $PORTNO -i "$workFolder"/id_rsa linux@localhost "sudo apt-get update --fix-missing"
		extraAnsibleArgs="-e ansible_python_interpreter=/usr/bin/python3"
	fi

	[[ ! -d "$workFolder/openjdk-infrastructure"  ]] && git clone -b "$gitBranch" "$gitURL" "$workFolder"/openjdk-infrastructure
	cd "$workFolder"/openjdk-infrastructure/ansible || exit 1;
	
	# Increase timeout as to stop privilege timeout issues
	# See: https://github.com/AdoptOpenJDK/openjdk-infrastructure/pull/1516#issue-470063061
	awk '{print}/^\[defaults\]$/{print "timeout = 30"}' < ansible.cfg > ansible.cfg.tmp && mv ansible.cfg.tmp ansible.cfg

	ansible-playbook -i "localhost:$PORTNO," --private-key "$workFolder"/id_rsa -u linux -b ${extraAnsibleArgs} --skip-tags adoptopenjdk,jenkins${skipFullSetup} playbooks/AdoptOpenJDK_Unix_Playbook/main.yml 2>&1 | tee "$pbLogPath"
	if grep -q 'failed=[1-9]\|unreachable=[1-9]' "$pbLogPath"; then
		echo "PLAYBOOK FAILED"
		destroyVM
		exit 1;
	fi

	if [[ "$buildJDK" == true ]]; then
		local buildLogPath="$workFolder/logFiles/$OS.$ARCHITECTURE.build_log"
		local buildRepoArgs="-f $buildFork -b $buildBranch"
		
		ssh linux@localhost -p "$PORTNO" -i "$workFolder"/id_rsa "git clone -b "$gitBranch" "$gitURL" \$HOME/openjdk-infrastructure && \$HOME/openjdk-infrastructure/ansible/pbTestScripts/buildJDK.sh --version $jdkToBuild $buildVariant $buildRepoArgs" 2>&1 | tee "$buildLogPath"
		if grep -q '] Error' "$buildLogPath" || grep -q 'configure: error' "$buildLogPath"; then
			echo BUILD FAILED
			destroyVM
			exit 127
		fi

		if [[ "$testJDK" == true ]]; then
			local testLogPath="$workFolder/logFiles/$OS.$ARCHITECTURE.test_log"

			ssh linux@localhost -p "$PORTNO" -i "$workFolder"/id_rsa "\$HOME/openjdk-infrastructure/ansible/pbTestScripts/testJDK.sh" 2>&1 | tee "$testLogPath"
			if ! grep -q 'FAILED: 0' "$testLogPath"; then
				echo TEST FAILED
				destroyVM
				exit 127
			fi
		fi	
	fi
	if [[ "$retainVM" == false ]]; then
		destroyVM
		echo "Removing disk image"
		rm -f ${workFolder}/${OS}.${ARCHITECTURE}.dsk
	fi
}

destroyVM() {	
	local PID=$(ps -aux | grep "$PORTNO" | grep -v "grep" | awk '{ print $2 }')
	echo "Killing this process: $PID"
	kill $PID
}

processArgs $*
defaultVars
setupWorkspace
runImage
runPlaybook
