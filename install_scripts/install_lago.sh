#!/bin/bash -e

REPONAME="ovirt-system-tests"
REPOURL="https://gerrit.ovirt.org"


exit_error() {
    ! [[ -z "$1" ]] && echo "ERROR: $1"
    ! [[ -z "$2" ]] && exit "$2"
    exit 1
}

check_virtualization() {
  if dmesg | grep -q 'kvm: disabled by BIOS'; then
      echo "Please enable virtualization in BIOS"
      exit 1
  else
      echo "Virtualization extension is enabled"
  fi
}

check_cpu_man() {
  if lscpu | grep -q 'Model name:\s*Intel'; then
    echo intel
  else
    echo amd
  fi
}

enable_nested() {
  local cpu_man=$(check_cpu_man)
  local is_enabled=$(cat /sys/module/kvm_"$cpu_man"/parameters/nested)
  if [[ "$is_enabled" == 'N' ]]; then
      echo "Enabling nested virtualization..."
      echo "options kvm-$cpu_man nested=y" >> /etc/modprobe.d/kvm-"$cpu_man".conf
      echo "Please restart and rerun installation"
      exit 1
  else
      echo "Nested virtualization is enabled"
  fi
}

install_lago() {
    echo "Installing lago"
    yum install -y python-lago python-lago-ovirt
}

add_lago_repo() {
    local distro
    local distro_str
    distro_str=$(rpm -E "%{?dist}") || exit_error "rpm command not found, only \
      RHEL/CentOS/Fedora are supported"

    if [[ $distro_str == ".el7" ]]; then
        distro="el"
        if [[ $(rpm -E "%{?centos}") == "7" ]]; then
            echo "Detected distro is CentOS 7"
            echo "Adding EPEL repository"
            yum -y install epel-release
        else
            echo "
            Detected distro is RHEL 7, please ensure you have the following
            repositories enabled:

            rhel-7-server-rpms
            rhel-7-server-optional-rpms
            rhel-7-server-extras-rpms
            rhel-7-server-rhv-4-mgmt-agent-rpms

            And EPEL, which can be installed(after enabling the above
            repositories), by running:

              yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm

            Continuing installation, if it fails on missing packages,
            try configuring the repositories and re-try.

            If you need any help, feel free to email: infra@ovirt.org
            "
        fi
    elif [[ $distro_str =~ ^.fc2[45]$ ]]; then
        echo "Detected distro is Fedora"
        distro="fc"
    else
        exit_error "Unsupported distro: $distro_str, Supported distros: \
            fc24, fc25, el7."
    fi
    echo "Adding Lago repositories.."
    cat > /etc/yum.repos.d/lago.repo <<EOF
[lago]
baseurl=http://resources.ovirt.org/repos/lago/stable/0.0/rpm/${distro}\$releasever
name=Lago
enabled=1
gpgcheck=0

[ci-tools]
baseurl=http://resources.ovirt.org/repos/ci-tools/${distro}\$releasever
name=ci-tools
enabled=1
gpgcheck=0
EOF
}

post_install_conf_for_lago() {
    echo "Configuring permissions"
    local user_home
    if [[ "$user" != "root" ]]; then
        user_home=$(eval echo "~$user")
        usermod -a -G lago "$user"
        usermod -a -G qemu "$user"
        chmod g+x "$user_home"
    else
        chmod g+x "/root"
    fi

    usermod -a -G "$user" qemu
}

enable_libvirt() {
    echo "Starting libvirt"
    systemctl restart libvirtd
    systemctl enable libvirtd
}

run_suite() {
    sudo -u "$user" bash <<EOF
if [[ ! "$suite" ]]; then
    exit 0
fi

echo "Running $REPONAME"
# clone or pull if already exist
if [[ -d "$REPONAME" ]]; then
    cd "$REPONAME"
    git pull "$REPOURL"/"$REPONAME"
else
    git clone "$REPOURL"/"$REPONAME" &&
    cd "$REPONAME"
fi
# check if the suite exists
if [[ "$?" == "0" ]] && [[ -d "$suite" ]]; then
    ./run_suite.sh "$suite"
else
    echo "Suite $suite wasn't found"
    exit 1
fi
EOF
}

print_help() {
  cat<<EOH
Usage: $0 user_name [suite_to_run]

Will install Lago and then clone oVirt system tests to the
current directory and run suite_to_run

The required permissions to run lago will be given to user_name.

If suite_to_run isn't specified Lago will be installed and no
suite will be run.
EOH
}

check_input() {
    id -u "$1" > /dev/null ||
    {
        echo "User $1 doesn't exist"
        print_help
        exit 1
    }
}

main() {
    check_input "$1"
    user="$1"
    suite="$2"
    check_virtualization
    enable_nested
    add_lago_repo
    install_lago
    post_install_conf_for_lago
    enable_libvirt
    run_suite
}

main "$@"
