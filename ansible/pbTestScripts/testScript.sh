#!/bin/bash
set -u

branchName='NULL'
folderName=''
gitURL=''
vagrantOS=''
retainVM=false
testNativeBuild=false

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
			"--VM" | "-vm" )
				retainVM=true;;
			"--URL" | "-u" )
				gitURL="$1"; shift;;
			"--help" | "-h" )
				usage; exit 0;;
			*) echo >&2 "Invalid option: ${opt}"; echo "This option was unrecognised."; usage; exit 1;;
		esac
	done
}

usage()
{
	echo
	echo "Usage: ./testScript.sh 	--vagrantfile | -v <OS_Version>		Specifies which OS the VM is
					--all | -a 				Builds and tests playbook through every OS
					--VM | -vm				Option to retain the VM once building them
					--build | -b				Option to enable testing a native build on the VM
					--URL | -u <GitURL>			The URL of the git repository
					--help | -h				Displays this help message"
}

checkVagrantOS()
{
	case "$vagrantOS" in
		"Ubuntu1604" | "U16" | "u16" )
			vagrantOS="Ubuntu1604";;
		"Ubuntu1804" | "U18" | "u18" )
			vagrantOS="Ubuntu1804";;
		"CentOS6" | "centos6" | "C6" | "c6" )
			vagrantOS="CentOS6" ;;
		"CentOS7" | "centos7" | "C7" | "c7" )
			vagrantOS="CentOS7" ;;
		"all" ) ;;
		*) echo "Not a currently supported OS" ; vagrantOSList; exit 1;
	esac
}

vagrantOSList()
{
	echo
	echo "Currently supported Vagrant OSs :
		- Ubuntu1604
		- Ubuntu1804
		- CentOS6
		- CentOS7"
	echo
}

setupFiles()
{
	cd $HOME
	mkdir -p adoptopenjdkPBTests || true
	cd adoptopenjdkPBTests
	mkdir -p logFiles || true
}

setupGit()
{
	cd $HOME/adoptopenjdkPBTests
	if [ "$branchName" == "NULL" ]; then
		echo "Detected as the master branch"
		if [ ! -d "$folderName-master" ]; then
   			git clone $gitURL
			mv $folderName $folderName-master
		else
			cd "$folderName-master"
    			git pull $gitURL
		fi
	else
		echo "Branch detected"
		if [ ! -d "$folderName-$branchName" ]; then
  			git clone -b $branchName --single-branch $gitURL
			mv $folderName "$folderName-$branchName"
		else
			cd "$folderName-$branchName"
			git pull origin $branchName
		fi
	fi
}

testBuild()
{
	vagrant ssh -c "git clone https://github.com/AdoptOpenJDK/openjdk-build"
	vagrant ssh -c "cd /vagrant/pbTestScripts && ./buildJDK.sh"
}

# Takes the OS as arg 1
startVMPlaybook()
{
	local OS=$1
	if [ "$branchName" == "NULL" ]; then
		cd $HOME/adoptopenjdkPBTests/$folderName-master/ansible
		branchName="master"
	else
		cd $HOME/adoptopenjdkPBTests/$folderName-$branchName/ansible
	fi
	ln -sf Vagrantfile.$OS Vagrantfile
	vagrant up
	# Remotely moves to the correct directory in the VM and builds the playbook. Then logs the VM's output to a file, in a separate directory
	vagrant ssh -c "cd /vagrant/playbooks/AdoptOpenJDK_Unix_Playbook && sudo ansible-playbook --skip-tags "adoptopenjdk,jenkins" main.yml" 2>&1 | tee ~/adoptopenjdkPBTests/logFiles/$folderName.$branchName.$OS.log
	if [[ "$testNativeBuild" = true ]]; then
		testBuild
	fi
	vagrant halt
}

destroyVM()
{
	printf "Destroying Machine . . .\n"
	vagrant destroy -f
}

# Takes in OS as arg 1, branchName as arg 2
searchLogFiles()
{
	cd $HOME/adoptopenjdkPBTests/logFiles
	if grep -q 'failed=[1-9]' *$2.$1.log
	then
		printf "\n$1 Failed\n"
	elif grep -q '\[ERROR\]' *$2.$1.log
	then
		printf "\n$1 playbook was stopped\n"
	else
		printf "\n$1 playbook succeeded\n"
	fi
}

# Takes in the URL passed to the script, and extracts the folder name, branch name and builds the gitURL to be used later on.
splitURL()
{
	#IFS stands for Internal Field Seperator and determines the delimiter for splitting.
	IFS='/' read -r -a array <<< "$gitURL"
	if [ ${array[@]: -2:1} == 'tree' ]
	then
		gitURL=""
		branchName=${array[@]: -1:1}
		folderName=${array[@]: -3:1}
		unset 'array[${#array[@]}-1]'
		unset 'array[${#array[@]}-1]'
		for i in "${array[@]}"
		do
			gitURL="$gitURL$i/"
		done
	else
		folderName=${array[@]: -1:1}
	fi
}
# var1 = GitURL, var2 = y/n for VM retention
processArgs $*
splitURL
checkVagrantOS
setupFiles
setupGit
# Testing all of the OSs
if [ "$vagrantOS" == "all" ]; then
	for OS in Ubuntu1604 Ubuntu1804 CentOS6 CentOS7
	do
		startVMPlaybook $OS
		if [[ "$retainVM" = false ]]
		then
			destroyVM
		fi
	done
	for OS in Ubuntu1604 Ubuntu1804 CentOS6 CentOS7
	do
		searchLogFiles $OS $branchName
	done
else
	startVMPlaybook $vagrantOS
		if [[ "$retainVM" = false ]]
		then
			destroyVM
		fi
	searchLogFiles $vagrantOS $branchName
fi
