#!/bin/bash
set -eu

gitFork=''
gitBranch=''
buildFork=''
buildBranch=''
vagrantOS=''
retainVM=false
testNativeBuild=false
runTest=false
vmHalt=true
cleanWorkspace=false
newVagrantFiles=false
fastMode=false
skipFullSetup=''
jdkToBuild=''
buildHotspot=''
buildBisheng=''
testDocker=false
scriptPath=$(realpath $0)

# Takes all arguments from the script, and determines options
processArgs()
{
	while [[ $# -gt 0 ]] && [[ ."$1" = .-* ]] ; do
		local opt="$1";
		shift;
		case "$opt" in
			"--Vagrantfile" | "-v" )
				vagrantOS="$1"; shift;;
			"--all" | "-a" )
				vagrantOS="all";;
			"--build" | "-b" )
				testNativeBuild=true;;
			"--JDK-Version" | "-jdk" )
				jdkToBuild="$1"; shift;;
			"--retainVM" | "-r" )
				retainVM=true;;
			"--fork" | "-f" )
				gitFork="$1"; shift;;
			"--branch" | "-br" )
				gitBranch="$1"; shift;;
			"--test" | "-t" )
				runTest=true;;
			"--no-halt" | "-nh" )
				vmHalt=false;;
			"--clean-workspace" | "-c" )
				cleanWorkspace=true;;
			"--new-vagrant-files" | "-nv" )
				newVagrantFiles=true;;
			"--skip-more" | "-sm" )
				fastMode=true;;
			"--build-fork" | "-bf" )
				buildFork="--fork $1"; shift;;
			"--build-branch" | "-bb" )
				buildBranch="--branch $1"; shift;;
			"--build-hotspot" )
				buildHotspot="--hotspot";;
			"--build-bisheng" )
				buildBisheng="--bisheng";;
			"--test-docker" )
				testDocker=true;;
			"--help" | "-h" )
				usage; exit 0;;
			*) echo >&2 "Invalid option: ${opt}"; echo "This option was unrecognised."; usage; exit 1;;
		esac
	done
}

usage()
{
	echo "Usage: ./vagrantPlaybookCheck.sh [options] (-a|-v <OS>)
  --vagrantfile | -v <OS>        Specifies which OS/distribution to test
  --all | -a                     Builds and tests playbook through every OS
  --retainVM | -r                Option to retain the VM and folder after completion
  --build | -b                   Option to enable testing a native build on the VM
  --JDK-Version | -jdk <Version> Specify which JDK to build, if build is specified
  --build-fork | -bf             Specify the fork of openjdk-build to build from (Default: adoptopenjdk)
  --build-branch | -bb           Specify the branch of the fork to build from (Default: master)
  --build-hotspot                Build the JDK with Hotspot (Default: OpenJ9)
  --build-bisheng                Build the JDK with Bisheng (Default: OpenJ9)
  --clean-workspace | -c         Remove the old work folder if detected
  --fork | -f                    Specify the fork of openjdk-infrastructure to run the playbook from (Default: adoptopenjdk)
  --branch | -br                 Specify the branch of the infrastructure fork (Default: master)
  --test | -t                    Runs a quick test on the built JDK
  --no-halt | -nh                Option to stop the vagrant VMs halting
  --new-vagrant-files | -nv      Use vagrantfiles from the the specified git repository
  --skip-more | -sm              Run playbook faster by excluding things not required by buildJDK
  --help | -h                    Displays this help message"
}

checkVars()
{
	if [ "$vagrantOS" == "" ]; then
		usage
		echo "ERROR: No Vagrant OS specified - Use -h for help, -a for all or -v with one of the following:"
		ls -1 ../vagrant/Vagrantfile.* | cut -d. -f4
		exit 1
	fi
	if [[ "$runTest" == true && "$testNativeBuild" == false ]]; then 
		echo "Unable to test an unbuilt JDK. Ignoring '--test' argument."
		runTest=false
	fi
	#Sets WORKSPACE to home if WORKSPACE is empty or undefined. 
	if [ ! -n "${WORKSPACE:-}" ]; then
		echo "WORKSPACE not found, setting it as environment variable 'HOME'"
		WORKSPACE=$HOME
	fi
	if [ "$gitBranch" == "" ]; then
		echo "No branch specified; Defaulting to 'master'"
		gitBranch="master"
	fi
	if [ "$gitFork" == "" ]; then
		echo "No Fork specified; Defaulting to 'adoptopenjdk'"
		gitFork="adoptopenjdk"
	fi
	if [[ "$retainVM" == false && "$vmHalt" == false ]]; then
		echo "Must halt the VM to destroy it; Ignoring '--no-halt' option"
		vmHalt=true;
	fi
        if [[ ! $(vagrant plugin list | grep 'disksize') ]]; then
                echo "Can't find vagrant-disksize plugin, installing . . ."
                vagrant plugin install vagrant-disksize
        fi
        if [[ ! $(vagrant plugin list | grep 'rsync-back') ]]; then
                echo "Can't find vagrant-rsync-back plugin, installing . . ."
                vagrant plugin install vagrant-rsync-back
        fi
	if [[ "$fastMode" == true ]]; then
		skipFullSetup=",nvidia_cuda_toolkit"
		case "$jdkToBuild" in
			"jdk8" )
				skipFullSetup="$skipFullSetup,MSVS_2017";
				if [ "$buildHotspot" != "" ]; then
					skipFullSetup="$skipFullSetup,MSVS_2010,VS2010_SP1"
				fi
				;;
                	*)
				skipFullSetup="$skipFullSetup,MSVS_2010,VS2010_SP1,MSVS_2013";;
		esac
	fi
	jdkToBuild="--version $jdkToBuild"
}

checkVagrantOS()
{
        local vagrantOSList
        if [[ "$newVagrantFiles" = "true" ]]; then
                cd ${WORKSPACE}/adoptopenjdkPBTests/${gitFork}-${gitBranch}/ansible/vagrant
        else    
                cd ${scriptPath%/*}/../vagrant
        fi
        vagrantOSList=$(ls -1 Vagrantfile.* | cut -d. -f 2)
        if [[ -f "Vagrantfile.${vagrantOS}" ]]; then
                echo "Vagrantfile Detected"
        elif [[ "$vagrantOS" == "all" ]]; then
                vagrantOS=$vagrantOSList
        else    
                echo "No Vagrantfile for $vagrantOS available - please select from one of the following"
                echo $vagrantOSList
                exit 1
        fi
        # The Windows VM is setup to use 5GB of memory, which can be an issue on machines with only 8GB installed.
        # See: https://github.com/AdoptOpenJDK/openjdk-infrastructure/pull/1532#issue-481189847
        if [[ "$vagrantOS" == "Win2012" && $(free | awk '/Mem:/ { print $2 }') -lt 8000000 ]]; then
                echo "Warning: Windows VM requires 5Gb of free memory to run. On laptops with only 8Gb this can be an issue."
                echo "Reducing the Windows VM memory requirement to 2560Mb."
                sed -i -e "s/5120/2560/g" Vagrantfile.Win2012
        fi
        if [[ "$vagrantOS" == "Win2016" && $(free | awk '/Mem:/ { print $2 }') -lt 8000000 ]]; then
                echo "Warning: Windows VM requires 5Gb of free memory to run. On laptops with only 8Gb this can be an issue."
                echo "Reducing the Windows VM memory requirement to 2560Mb."
                sed -i -e "s/5120/2560/g" Vagrantfile.Win2016
        fi
}

setupWorkspace()
{
	local workFolder=$WORKSPACE/adoptopenjdkPBTests
	local gitDirectory=${workFolder}/${gitFork}-${gitBranch}
	mkdir -p ${workFolder}/logFiles

	if [[ "$cleanWorkspace" = true && -d ${gitDirectory} ]]; then
		echo "Cleaning old workspace"
		rm -rf ${gitDirectory}
	elif [[ "$cleanWorkspace" = true && ! -d ${gitDirectory} ]]; then
		echo "No old workspace detected, moving on"
	fi

	if [ ! -d "${gitDirectory}" ]; then
		git clone -b ${gitBranch} --single-branch https://github.com/${gitFork}/openjdk-infrastructure ${gitDirectory}
	else
		cd ${gitDirectory}
		git pull
        fi
}

# Takes the OS as arg 1
startVMPlaybook()
{
	local OS=$1
	local vagrantPORT=""
	local pbLogPath="$WORKSPACE/adoptopenjdkPBTests/logFiles/${gitFork}.${gitBranch}.$OS.log"
	local ssh_args=""

	cd $WORKSPACE/adoptopenjdkPBTests/${gitFork}-${gitBranch}/ansible
	if [ "$newVagrantFiles" = "true" ]; then
	  ln -sf vagrant/Vagrantfile.$OS Vagrantfile
	else
	  ln -sf ${scriptPath%/*}/../vagrant/Vagrantfile.$OS Vagrantfile
	fi
	# Copy the machine's ssh key for the VMs to use, after removing prior files
	rm -f id_rsa.pub id_rsa
	ssh-keygen -q -f $PWD/id_rsa -t rsa -N ''

	# Add '-o KexAlgorithms=diffie-hellman-group1-sha1' to the Ansible ssh commands, for Solaris10
	# See: https://github.com/AdoptOpenJDK/openjdk-infrastructure/issues/1938
	if [ "$OS" == "Solaris10" ]; then
		sed -i 's/.*ControlPersist=60s.*/& -o KexAlgorithms=diffie-hellman-group1-sha1/g' ansible.cfg
		# Pre install Solaris Compiler on VM
		if [ -r /tmp/SolarisStudio12.3-solaris-x86-pkg ]; then
			cp -r /tmp/SolarisStudio12.3-solaris-x86-pkg .
		fi 
		ssh_args="-o KexAlgorithms=diffie-hellman-group1-sha1"
	fi

	# The BUILD_ID variable is required to stop Jenkins shutting down the wrong VMS 
	# See https://github.com/AdoptOpenJDK/openjdk-infrastructure/issues/1287#issuecomment-625142917
	BUILD_ID=dontKillMe vagrant up
	vagrantPORT=$(vagrant port | grep host | awk '{ print $4 }')

	rm -f playbooks/AdoptOpenJDK_Unix_Playbook/hosts.unx
	echo "[127.0.0.1]:${vagrantPORT}" >> playbooks/AdoptOpenJDK_Unix_Playbook/hosts.unx
	# Remove IP from known_hosts if already found
	# ssh-keygen -R will fail if the known_hosts file does not exist
	[ ! -r $HOME/.ssh/known_hosts ] && touch $HOME/.ssh/known_hosts && chmod 644 $HOME/.ssh/known_hosts
	ssh-keygen -R $(cat playbooks/AdoptOpenJDK_Unix_Playbook/hosts.unx)
	
	sed -i -e "s/.*hosts:.*/- hosts: all/g" playbooks/AdoptOpenJDK_Unix_Playbook/main.yml
	awk '{print}/^\[defaults\]$/{print "private_key_file = id_rsa"; print "remote_tmp = $HOME/.ansible/tmp"; print "timeout = 60"}' < ansible.cfg > ansible.cfg.tmp && mv ansible.cfg.tmp ansible.cfg
	
	ansible-playbook -i playbooks/AdoptOpenJDK_Unix_Playbook/hosts.unx -u vagrant -b --skip-tags adoptopenjdk,jenkins${skipFullSetup} playbooks/AdoptOpenJDK_Unix_Playbook/main.yml 2>&1 | tee $WORKSPACE/adoptopenjdkPBTests/logFiles/$gitFork.$gitBranch.$OS.log
	echo The playbook finished at : `date +%T`
	if ! grep -q 'unreachable=0.*failed=0' $pbLogPath; then
		echo PLAYBOOK FAILED 
		exit 1
	fi

	if [ "$OS" == "Solaris10" ]; then
		# Remove IP from known_hosts as the playbook installs an
		# alternate sshd which regenerates the host key infra#2244
		ssh-keygen -R $(cat playbooks/AdoptOpenJDK_Unix_Playbook/hosts.unx)
		ssh_args="$ssh_args -o StrictHostKeyChecking=no"
	fi

	if [[ "$testNativeBuild" = true ]]; then
		local buildLogPath="$WORKSPACE/adoptopenjdkPBTests/logFiles/${gitFork}.${gitBranch}.$OS.build_log"
    ssh -p ${vagrantPORT} $ssh_args -i $PWD/id_rsa vagrant@127.0.0.1 "cd /vagrant/pbTestScripts && bash buildJDK.sh $buildBranch $buildFork $jdkToBuild $buildHotspot $buildBisheng" 2>&1 | tee $buildLogPath
		echo The build finished at : `date +%T`
		if grep -q '] Error' $buildLogPath || grep -q 'configure: error' $buildLogPath; then
			echo BUILD FAILED
			exit 127
		fi

		if [[ "$runTest" = true ]]; then
			local testLogPath="$WORKSPACE/adoptopenjdkPBTests/logFiles/${gitFork}.${gitBranch}.$OS.test_log"
			ssh -p ${vagrantPORT} $ssh_args -i $PWD/id_rsa vagrant@127.0.0.1 "cd /vagrant/pbTestScripts && bash testJDK.sh" 2>&1 | tee $testLogPath
			echo The test finished at : `date +%T`
			if ! grep -q 'FAILED: 0' $testLogPath; then
				echo TEST FAILED
				exit 127
			fi
		fi
	fi

        if [[ "$testDocker" == "true" ]]; then
        	if [ "$OS" == "FreeBSD12" -o "$OS" == "CentOS8" -o "$OS" == "CentOS6" ]; then
        		echo Skipping docker test as we do not set it up on $OS
        	else
#			if ! ssh -p ${vagrantPORT} -i $PWD/id_rsa vagrant@127.0.0.1 /usr/sbin/service docker status; then
#				echo WARNING: Docker service was not started on the VM ... Attempting to start
#	        		ssh -p ${vagrantPORT} -i $PWD/id_rsa vagrant@127.0.0.1 /usr/sbin/service docker start
#	        	fi
        		ssh -p ${vagrantPORT} -i $PWD/id_rsa vagrant@127.0.0.1 sudo docker run alpine /bin/echo Hello World from inside docker
			echo The docker validation finished at : `date +%T`
		fi
	fi
}

startVMPlaybookWin()
{
	local OS=$1
	local pbLogPath="$WORKSPACE/adoptopenjdkPBTests/logFiles/${gitFork}.${gitBranch}.$OS.log"
	local vagrantPort=

	cd $WORKSPACE/adoptopenjdkPBTests/${gitFork}-${gitBranch}/ansible
	if [ "$newVagrantFiles" = "true" ]; then
	  ln -sf vagrant/Vagrantfile.$OS Vagrantfile
	else
	  ln -sf ${scriptPath%/*}/../vagrant/Vagrantfile.$OS Vagrantfile
	fi

	# Remove the Hosts files if they're found
	rm -f playbooks/AdoptOpenJDK_Windows_Playbook/hosts.*
	# The BUILD_ID variable is required to stop Jenkins shutting down the wrong VMS
        # See https://github.com/AdoptOpenJDK/openjdk-infrastructure/issues/1287#issuecomment-625142917
	BUILD_ID=dontKillMe vagrant up
	
	# Rearm the evaluation license for 180 days to stop the VMs shutting down
	# See: https://github.com/AdoptOpenJDK/openjdk-infrastructure/issues/2056
	vagrant winrm --shell cmd -c "slmgr.vbs /rearm //b"
	vagrant reload

	# 5986 refers to the winrm_ssl port on the guest
	# See: https://github.com/AdoptOpenJDK/openjdk-infrastructure/issues/1504#issuecomment-672930832
	vagrantPort=$(vagrant port |  awk '/5986/ { print $4 }')
	echo "[127.0.0.1]:$vagrantPort" >> playbooks/AdoptOpenJDK_Windows_Playbook/hosts.win
	echo "This is the content of hosts.win : " && cat playbooks/AdoptOpenJDK_Windows_Playbook/hosts.win
	
	# Changes the value of "hosts" in main.yml
	sed -i'' -e "s/.*hosts:.*/- hosts: all/g" playbooks/AdoptOpenJDK_Windows_Playbook/main.yml
	# Uncomments and sets the ansible_password to 'vagrant', in adoptopenjdk_variables.yml
	sed -i'' -e "s/.*ansible_password.*/ansible_password: vagrant/g" playbooks/AdoptOpenJDK_Windows_Playbook/group_vars/all/adoptopenjdk_variables.yml
	# If "credssp" isn't found in adoptopenjdk_variables.yml
	if ! grep -q "credssp" playbooks/AdoptOpenJDK_Windows_Playbook/group_vars/all/adoptopenjdk_variables.yml;
	then
		# Add the "ansible_winrm_transport" to adoptopenjdk_variables.yml
		echo -e "\nansible_winrm_transport: credssp" >> playbooks/AdoptOpenJDK_Windows_Playbook/group_vars/all/adoptopenjdk_variables.yml
	fi
	
	# Run the ansible playbook on the VM & logs the output.
	ansible-playbook -i playbooks/AdoptOpenJDK_Windows_Playbook/hosts.win -u vagrant --skip-tags jenkins,adoptopenjdk${skipFullSetup} playbooks/AdoptOpenJDK_Windows_Playbook/main.yml 2>&1 | tee $pbLogPath
	echo The playbook finished at : `date +%T`
	if ! grep -q 'unreachable=0.*failed=0' $pbLogPath; then
		echo PLAYBOOK FAILED 
		exit 1
	fi
        
	if [[ "$testNativeBuild" = true ]]; then
		local buildLogPath="$WORKSPACE/adoptopenjdkPBTests/logFiles/${gitFork}.${gitBranch}.$OS.build_log"

		# Restarting the VM as the shared folder disappears after the playbook runs due to the restarts in the playbook
		vagrant halt && vagrant up

		# Restarting the VM may change the port number
		vagrantPort=$(vagrant port |  awk '/5985/ { print $4 }')

		# Run a python script to start the build on the Windows VM to give live stdout/stderr
		# See: https://github.com/AdoptOpenJDK/openjdk-infrastructure/issues/1296
		python pbTestScripts/startScriptWin.py -i "127.0.0.1:$vagrantPort" -a "$buildFork $buildBranch $jdkToBuild $buildHotspot" -b 2>&1 | tee $buildLogPath
		echo The build finished at : `date +%T`
		if grep -q '] Error' $buildLogPath || grep -q 'configure: error' $buildLogPath; then
			echo BUILD FAILED
			exit 127
		fi
	
		if [[ "$runTest" = true ]]; then
			local testLogPath="$WORKSPACE/adoptopenjdkPBTests/logFiles/${gitFork}.${gitBranch}.$OS.test_log"
			
			# Run a python script to start a test for the built JDK on the Windows VM
			python pbTestScripts/startScriptWin.py -i "127.0.0.1:$vagrantPort" -t 2>&1 | tee $testLogPath
			echo The test finished at : `date +%T`
			if ! grep -q 'FAILED: 0' $testLogPath; then 
				echo TEST FAILED
				exit 127
			fi
		fi
	fi
}

destroyVM()
{
	local OS=$1
	echo "Destroying the $OS Machine"
	echo === `date +%T`: showing global status before pruning:
	vagrant global-status
	free
	echo === showing global status while pruning:
	vagrant global-status --prune
	echo === Determining VM to destroy:
	VM_TO_DESTROY=`vagrant global-status --prune | grep $OS | awk "/${gitFork}-${gitBranch}/ { print \\$1 }"`
	if [ ! -z "$VM_TO_DESTROY" ]; then
	  echo === Destroying VM with id $VM_TO_DESTROY
	  vagrant destroy -f $VM_TO_DESTROY
	else
	  echo === NOT DESTROYING ANY VM as no suitable ID was found searching for $OS and ${gitFork}-${gitBranch}
	fi
        echo === Final status:
        vagrant global-status --prune
        free
}

processArgs $*
checkVars
setupWorkspace
checkVagrantOS

echo "Testing on the following OSs: $vagrantOS"
for OS in $vagrantOS
do
	if [[ "$OS" == "Win2012" ]] || [[ "$OS" == "Win2016" ]]; then
		startVMPlaybookWin $OS
	else
		startVMPlaybook $OS
	fi
  	if [[ "$vmHalt" == true ]]; then
                vagrant halt 
	fi
	if [[ "$retainVM" == false ]]; then
		destroyVM $OS
	fi
done
