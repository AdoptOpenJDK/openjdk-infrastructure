# Setting up AIX servers

-- Work in Progress -- (WIP)

1) AIX BASE Requirements
1a) X11 requirements
# OJDK requires X11 support
# Additional dependencies are installed by default
X11.adt.ext
# X11 Frame Buffers
X11.vfb
X11.base.lib

1b) AIX NLS/language support
# Highly recommended are the following multi-language support files
# https://github.com/AdoptOpenJDK/openjdk-infrastructure/pull/657#issuecomment-454308017
bos.iconv
bos.loc.com.CN
bos.loc.com.JP
bos.loc.com.utf
bos.loc.utf.EN_ZA
bos.loc.iso.en_ZA
bos.loc.iso.ja_JP
bos.loc.iso.ko_KR
bos.loc.iso.zh_CN
bos.loc.pc
bos.loc.utf.JA_JP
bos.loc.utf.KO_KR
bos.loc.utf.ZH_CN
bos.loc.utf.ZH_TW

1c) OPENSSL requirements
The most recent versions of openssh and openssl, in any case
openssl.base.1.0.2.1600 and later


1d) AIX base requirements to be able to use AIX Toolbox
OSS software packaged by AIX Toolbox will require the following filesets:
expect
tk
tcl

Additionally, the yum setup script (yum.sh) - if used, will require the ftp client. For AIX 7.2 that is a seperate fileset
bos.net.tcp.ftp

2) ## WIP ## Ansible playbook instructions

3) (build without jenkins-agent)
Rough Steps: WIP
* login as jenkins (as the user specific requirements, rbac, capabilities, ulimits are already there)
* git clone https://github.com/AdoptOpenJDK/openjdk-build.git
* cd openjdk-build/build-farm
*  ./make-adopt-build-farm.sh

## The build process should just start. If there are errors, they will need to be dealt with.

4) Additional Notes
One of the roles (rbac) is needed for some special Java functions - metronome and core dump.
The setup is performed by the AIX role 'rbac'

## Details of RBAC config to follow ##
